# QUESTIONS:
# - What do we do about links inside page content that link to other parts of the wiki? (i.e. Rinku links)
# - Permissions?

require 'tempfile'

#######################
## Mocked AR classes ##
#######################

if __FILE__ == $0
  class Page
    attr_reader :page_type, :name, :children, :attachments, :google_id
    def initialize(type, name, attachments, children, google_id = nil)
      @page_type = type
      @name = name
      @children = children
      @attachments = attachments
      @google_id = google_id
    end

    def body
      <<-EOF
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="UTF-8">
          <title>_#{name}</title>
        </head>
        <body>
          <p>Foo Bar</p>
        </body>
        </html>
      EOF
    end
  end

  class Attachment
    attr_reader :filename
    def initialize(filename)
      @filename = filename
    end
  end
end

##############################################################################
## The exporting service, the only thing that actually matters in this file ##
##############################################################################

class Exporter
  attr_reader :service, :logger
  def initialize(root_folder, pages, service, logger)
    @root_folder = root_folder
    @pages = pages
    @service = service
    @logger = logger
  end

  def export!
    root = create_or_find_folder(@root_folder)
    @pages.each { |page| export_page(page, root) }
  end

  private

  def create_or_find_folder(name, parents = nil)
    query = "name='#{name}' and mimeType='application/vnd.google-apps.folder'"
    query += " and '#{parents}' in parents" if parents
    response = service.list_files(q: query)
    if response.files.empty?
      logger.debug "Creating folder #{name}"
      options = { name: name, mime_type: 'application/vnd.google-apps.folder' }
      options.merge!(parents: [parents]) if parents
      service.create_file(options, fields: 'id').id
    else
      logger.debug "Folder #{name} already found, parents: (#{parents})"
      response.files.first.id
    end
  end

  def create_or_find_dump(page, folder_id)
    response = service.list_files(q: "name='_#{page.name}' and mimeType='application/vnd.google-apps.document' and '#{folder_id}' in parents")
    if response.files.empty?
      logger.debug "Creating dump file _#{page.name}"
      page_dump = Tempfile.new('migration')
      begin
        page_dump.write page.body
        page_dump.size #flush the buffer

        service.create_file({ name: "_#{page.name}", parents: [folder_id], mime_type: 'application/vnd.google-apps.document' }, upload_source: page_dump.path, fields: 'id', content_type: 'text/html').id
      ensure
        page_dump.close!
      end
    else
      logger.debug "Already created dump file _#{page.name}"
      response.files.first.id
    end
  end

  def create_or_find_attachment(file, folder)
    response = service.list_files(q: "name='#{file}' and '#{folder}' in parents")
    if response.files.empty?
      logger.debug "Attaching file #{file}"
      service.create_file({ name: file, parents: [folder] }, upload_source: file, fields: 'id').id
    else
      logger.debug "Already created attachment #{file}"
      response.files.first.id
    end
  end

  def handle_document(parent, page)
    old_parents = service.get_file(page.google_id, fields: 'parents').parents.join(',')
    if old_parents != parent
      logger.debug "Moving file #{page.name} to #{parent}"
      service.update_file(page.google_id, add_parents: parent, remove_parents: old_parents, fields: 'id, parents')
    else
      logger.debug "Location for document #{page.name} already correct"
    end
  end

  def handle_attachments(page, folder_id)
    id = create_or_find_folder('_Attachments', folder_id)
    page.attachments.each do |attachment|
      create_or_find_attachment(attachment.filename, id)
    end
  end

  def handle_page(parent, page)
    id = create_or_find_folder(page.name, parent)
    create_or_find_dump(page, id)
    handle_attachments(page, id)
    id
  end

  def export_page(page, parent)
    logger.info "Processing '#{page.name}' under parent: #{parent}"
    migration_id = case page.page_type
    when 'google_spreadsheet', 'google_document'
      handle_document(parent, page)
    else
      handle_page(parent, page)
    end
    page.children.each do |child|
      export_page(child, migration_id)
    end
    logger.debug "Finished processing '#{page.name}'"
  end
end

if __FILE__ == $0
  require 'logger'
  require 'yaml'
  require 'fileutils'

  require 'rubygems'
  require 'bundler'
  Bundler.setup

  require 'google/apis/drive_v3'
  require 'googleauth'
  require 'googleauth/stores/file_token_store'

  ###############################
  ## Set this stuff up however ##
  ###############################

  OOB_URI = 'urn:ietf:wg:oauth:2.0:oob'
  APPLICATION_NAME = 'Drive API Uploader'
  CLIENT_SECRETS_PATH = 'client_secret.json'
  CREDENTIALS_PATH = File.join(Dir.home, '.credentials', 'uploader.yml')
  SCOPE = Google::Apis::DriveV3::AUTH_DRIVE

  def authorize
    FileUtils.mkdir_p(File.dirname(CREDENTIALS_PATH))
    client_id = Google::Auth::ClientId.from_file(CLIENT_SECRETS_PATH)
    token_store = Google::Auth::Stores::FileTokenStore.new(file: CREDENTIALS_PATH)
    authorizer = Google::Auth::UserAuthorizer.new(client_id, SCOPE, token_store)
    user_id = 'default'
    credentials = authorizer.get_credentials(user_id)
    if credentials.nil?
      system "open '#{authorizer.get_authorization_url(base_url: OOB_URI)}'"
      puts "Enter your token:"
      code = gets
      credentials = authorizer.get_and_store_credentials_from_code(user_id: user_id, code: code, base_url: OOB_URI)
    end
    credentials
  end

  ################################################################
  ## Our service and logger we need to inject into our exporter ##
  ################################################################

  @drive_service = Google::Apis::DriveV3::DriveService.new
  @drive_service.client_options.application_name = APPLICATION_NAME
  @drive_service.authorization = authorize

  @logger = Logger.new(STDOUT)
  @logger.level = Logger::INFO

  ##################################
  ## Helpers for loading up mocks ##
  ##################################

  def ensure_drive_document(type, name)
    return nil unless ['google_spreadsheet', 'google_document'].include?(type)
    mime_type = "application/vnd.google-apps.#{type.split('_')[1]}"
    response = @drive_service.list_files(q: "name='#{name}' and mimeType='#{mime_type}'")
    if response.files.empty?
      @logger.info "Seeding: Creating #{type} #{name}"
      options = { name: name, mime_type: mime_type }
      @drive_service.create_file(options, fields: 'id').id
    else
      @logger.info "Seeding: File #{name} found"
      response.files.first.id
    end
  end

  def ensure_attachment(name)
    @logger.info "Seeding: Touching attachment #{name}"
    FileUtils.touch(name)
    Attachment.new(name)
  end

  def construct_node(node)
    Page.new(node[:type], node[:name], node[:attachments].map {|attachment| ensure_attachment(attachment[:filename])}, node[:children].map {|child| construct_node(child)}, ensure_drive_document(node[:type], node[:name]))
  end

  mocks = YAML.load_file(File.join(File.dirname(__FILE__), 'mock.yml'))
  top_level_pages = mocks[:pages].map do |page|
    construct_node(page)
  end

  #####################################################################################
  ## Actual work here, should be able to replace second parameter with AR collection ##
  #####################################################################################

  # top_level_pages = Page.where(parent_id: nil)
  Exporter.new(mocks[:folder], top_level_pages, @drive_service, @logger).export!
end
