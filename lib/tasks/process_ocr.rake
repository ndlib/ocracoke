namespace :iiifsi do
  task :process_ocr => :environment do
    # Script that queries Sal for all Technician newspapers and
    # creates OCR for each page and then combined resources for
    # each resource.

    lock_file_name = '/tmp/process_technician_ocr.lock'

    # If the lock file does not exist we create it.
    unless File.exist?(lock_file_name)
      FileUtils.touch(lock_file_name)
    end

    # Unless we get a lock on the lockfile we exit immediately.
    # We keep a file handle open so that we retain the lock the whole time.
    flock_file = File.open(lock_file_name, 'w')
    unless flock_file.flock(File::LOCK_NB|File::LOCK_EX)
      puts "Can't get lock so exiting! No OCR processed."
      exit
    end

    # set up some variables
    @http_client = HTTPClient.new
    @temp_directory = File.join Dir.tmpdir, 'process_ocr'
    unless File.exist? @temp_directory
      FileUtils.mkdir @temp_directory
    end
    # chanage to directory to put tesseract outputs
    Dir.chdir @temp_directory
    # Clear out temp_directory in case anything is in it
    dir_glob = File.join @temp_directory, '*'
    Dir.glob(dir_glob).each do |file|
      FileUtils.rm file
    end

    # Make the request to Sal for the results for the page
    def get_technician_results_for_page(page: 1)
      # FIXME: &q=technician-v9n22-1929-03-09
      url_extra = ''
      url_extra = "&q=april+1&f[resource_decade_facet][]=1980s"
      url = "http://d.lib.ncsu.edu/collections/catalog.json?f[ispartof_facet][]=Technician&per_page=10&page=#{page}#{url_extra}"
      response = @http_client.get url
      json = response.body
      JSON.parse json
    end

    # Based on a identifier determine if all the OCR files already exist
    def ocr_already_exists?(identifier)
      File.size?(final_txt_filepath(identifier)) && File.size?(final_hocr_filepath(identifier))
      # FIXME: && File.size?(final_pdf_filepath(identifier))
    end

    # Final file paths where files will be stored. This is not the same as the
    # location for the temporary processing.
    def directory_for_first_two(identifier)
      first_two_of_identifier = identifier.slice(0, 2)
      File.join Rails.configuration.iiifsi['ocr_directory'], first_two_of_identifier
    end
    def directory_for_identifier(identifier)
      File.join directory_for_first_two(identifier), identifier
    end
    def final_output_base_filepath(identifier)
      File.join directory_for_identifier(identifier), identifier
    end
    def final_txt_filepath(identifier)
      final_output_base_filepath(identifier) + '.txt'
    end
    def final_hocr_filepath(identifier)
      final_output_base_filepath(identifier) + '.hocr'
    end
    def final_pdf_filepath(identifier)
      final_output_base_filepath(identifier) + '.pdf'
    end
    def final_json_file_filepath(identifier)
      final_output_base_filepath(identifier) + '.json'
    end

    # Temporary filepaths
    def temporary_filepath(identifier, extension)
      File.join @temp_directory, identifier + extension
    end

    def parse_hocr_title(title)
      parts = title.split(';').map(&:strip)
      info = {}
      parts.each do |part|
        sections = part.split(' ')
        sections.shift
        if /^bbox/.match(part)
          info['x0'], info['y0'], info['x1'], info['y1'] = sections
        elsif /^x_wconf/.match(part)
          info['c'] = sections.first
        end
      end
      info
    end

    def create_word_boundary_json(identifier)
      # final_json_file_filepath(identifier)
      doc = File.open(final_hocr_filepath(identifier)) { |f| Nokogiri::HTML(f) }
      json = {}
      doc.css('span.ocrx_word').each do |span|
        text = span.text
        # Filter out non-word characters
        word_match = text.match /\w+/
        next if word_match.nil?
        word = word_match[0]
        next if word.length < 3
        json[word] ||= []
        title = span['title']
        info = parse_hocr_title(title)
        # FIXME: is it possible here to turn the bounding box numbers into integers?
        json[word] << info
      end
      File.open(final_json_file_filepath(identifier), 'w') do |fh|
        fh.puts json.to_json
      end
    end

    # Given a doc iterate over each of the jp2s and process OCR for them
    def process_ocr_for_each_page(doc)
      doc['jp2_filenames_sms'].each do |identifier|
        puts identifier

        # TODO: allow turning this feature off via CLI
        if ocr_already_exists?(identifier)
          puts "OCR already exists. Skipping #{identifier}"
          next
        end

        # create tempfile for image
        request_file_format = 'jpg'
        tmp_download_image = Tempfile.new([identifier, ".#{request_file_format}"])
        tmp_download_image.binmode
        # IIIF URL
        url = IiifUrl.from_params identifier: identifier, format: request_file_format
        # get image with httpclient
        response = @http_client.get url
        # write image to tempfile
        tmp_download_image.write response.body

        # create outputs (txt, hOCR, PDF) with tesseract.
        # Look under /usr/share/tesseract/tessdata/configs/ to see hocr and pdf values.
        # Do not create the PDF here. Instead just take the hOCR output and
        # use a lower resolution (more compressed) version of the JPG image of the same
        # dimensions to combine the hOCR with the JPG into a PDF of reasonable size.
        `tesseract #{tmp_download_image.path} #{identifier} -l eng hocr`

        # create directory to put final outputs
        tesseract_output_directory = directory_for_identifier(identifier)
        FileUtils.mkdir_p tesseract_output_directory

        # move the txt from tesseract to final location
        FileUtils.mv temporary_filepath(identifier, '.txt'), final_txt_filepath(identifier)

        # Create a downsampled smaller version of the JPG
        `convert -density 150 -quality 20 #{tmp_download_image.path} #{temporary_filepath(identifier, '.jpg')}`

        # create the PDF with hocr-pdf
        # FIXME: sometimes hocr-pdf fails so no PDF gets created.
        begin
          `hocr-pdf #{@temp_directory} > #{temporary_filepath(identifier, '.pdf')}`
        rescue
        end

        # move the hOCR to the final location
        FileUtils.mv temporary_filepath(identifier, '.hocr'), final_hocr_filepath(identifier)

        # move the PDF to final location if it exists
        if File.exist?(temporary_filepath(identifier, '.pdf')) && File.size?(temporary_filepath(identifier, '.pdf'))
          FileUtils.mv temporary_filepath(identifier, '.pdf'), final_pdf_filepath(identifier)
        end

        # remove the downsampled JPG
        FileUtils.rm temporary_filepath(identifier, '.jpg')

        # Do a check that the files were properly created
        if ocr_already_exists?(identifier)
          # extract words and boundaries from hOCR into a JSON file
          create_word_boundary_json(identifier)
          # Set permissions
          FileUtils.chmod_R('ug=rwX,o=rX', directory_for_first_two(identifier))
        else
          # remove them if they don't exist
          FileUtils.rm_rf directory_for_identifier(identifier)
        end

        # remove the temporary file
        tmp_download_image.unlink
      end
    end

    def concatenate_pdf(doc)
      # Use pdunite to join all the PDFs into one
      pdfunite = "pdfunite"
      pdf_pages = []
      doc['jp2_filenames_sms'].each do |identifier|
        # If the file exists then add it to the pdfunite command
        if File.exist? final_pdf_filepath(identifier)
          pdf_pages << final_pdf_filepath(identifier) + ' '
        end
      end
      # Add onto the end the path to the final resource PDF
      pdfunite << " #{pdf_pages.join(' ')} #{final_pdf_filepath(doc['id'])} "
      # Only try to create the combined PDF if all the pages have a PDF
      if pdf_pages.length == doc['jp2_filenames_sms'].length
        `#{pdfunite}`
      else
        puts "Some pages do not have a PDF. Skipping creation of combined PDF."
      end
    end

    def concatenate_txt(doc)
      text = ""
      doc['jp2_filenames_sms'].each do |identifier|
        text << File.read(final_txt_filepath(identifier))
      end
      File.open final_txt_filepath(doc['filename']), 'w' do |fh|
        fh.puts text
      end
    end

    # Given a doc create concatenated resources from them
    def concatenate_ocr_for_resource(doc)
      # Create directory for files at resource level
      unless File.exist? directory_for_identifier(doc["filename"])
        FileUtils.mkdir directory_for_identifier(doc["filename"])
      end

      #concatenate pdf
      concatenate_pdf(doc)

      # concatenate txt
      concatenate_txt(doc)

      # TODO: concatenate hOCR?

      # TODO: set proper permissions on combined files
    end

    # get the first page of results to find total_pages
    response = get_technician_results_for_page
    total_pages = response['response']['pages']['total_pages']

    # Yes, there's a duplicate request for the first page here, but this is a bit
    # simpler.
    total_pages
    5.times do |page|
      response = get_technician_results_for_page(page: page)
      response['response']['docs'].each do |doc|
        # A doc is a resource and can have multiple pages
        process_ocr_for_each_page(doc)
        concatenate_ocr_for_resource(doc)
      end
    end

    # unlock the file
    flock_file.flock(File::LOCK_UN)

  end
end