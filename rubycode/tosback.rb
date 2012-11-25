require 'nokogiri'
require 'open-uri'
require 'sanitize'
require 'mechanize' # will probably need to use this instead to handle sites that require session info
# require 'grit'

$rules_path = "../rules/"
$results_path = "../crawl/"
$log_dir = "../logs/"
$error_log = "errors.log"
$run_log = "run.log"
$modified_log = "modified.log"
$empty_log = "empty.log"

class TOSBack
  
  def initialize(xml)
    begin
      filecontent = File.open(xml)
      ngxml = Nokogiri::XML(filecontent)
    rescue
      log_stuff("Script had trouble opening this file: #{filename}",$error_log)
      @sitename = nil
      @docs = nil
      raise ArgumentError, "XML file couldn't be opened"
    ensure
      filecontent.close
    end
    
    @sitename = ngxml.xpath("//sitename[1]/@name").to_s
    @docs = []
     ngxml.xpath("//sitename/docname").each do |doc|
       docs << {:name => doc.at_xpath("./@name").to_s,:url => doc.at_xpath("./url/@name").to_s,:xpath => doc.at_xpath("./url/@xpath").to_s}
     end
    
  end #initialize
  
  def log_stuff(message,logfile)
    err_log = File.open("#{$log_dir}#{logfile}", "a")
    err_log.puts "#{Time.now} - #{message}\n"
    err_log.close
  end # log_stuff
  
  private :log_stuff
  attr_accessor :sitename, :docs
end # TOSBack

def log_stuff(message,logfile)
  err_log = File.open("#{$log_dir}#{logfile}", "a")
  err_log.puts "#{Time.now} - #{message}\n"
  err_log.close
end

def git_modified
  # git = Grit::Repo.new("../")
  git = IO.popen("git status")

  modified_file = File.open("#{$log_dir}#{$modified_log}", "w")
  modified_file.puts "These files were modified since the last commit:\n\n"
  # git.status.changed.each {|filename| modified_file.puts "#{filename[0]}\n"}
  git.each {|line| modified_file.puts line}
  modified_file.close
end

def strip_tags(data)
  data = Sanitize.clean(data, :remove_contents => ["script", "style"], :elements => %w[ abbr b blockquote br cite code dd dfn dl dt em i li ol p q s small strike strong sub sup u ul ], :whitespace_elements => []) # strips non-style html tags and removes content between <script> and <style> tags
  return data
end

def format_tos(tos_data)
  begin
  tos_data = strip_tags(tos_data) # uses Sanitize to strip html
  # puts "worked"
  rescue Encoding::CompatibilityError
    # puts "rescued"
    tos_data.encode!("UTF-8", :undef => :replace)
    tos_data = strip_tags(tos_data)
  rescue ArgumentError
    # puts "Argument error"
    tos_data.encode!('ISO-8859-1', {:invalid => :replace, :undef => :replace})
    tos_data.encode!('UTF-8', {:invalid => :replace, :undef => :replace})
    tos_data = strip_tags(tos_data)
  end

  tos_data.gsub!(/\s{2,}/," ") # changes big gaps of space to a single space
  tos_data.gsub!(/\.\s|;\s/,".\n") # adds new line char after all ". "'s
  tos_data.gsub!(/\n\s/,"\n") # removes single spaces at the beginning of lines
  tos_data.gsub!(/>\s*</,">\n<") # newline between tags
  
  return tos_data
end

def find_empty_crawls(path, byte_limit)
  Dir.glob("#{path}*") do |filename| # each dir in crawl
    next if filename == "." || filename == ".."
    
    if File.directory?(filename)
      files = Dir.glob("#{filename}/*.txt")
      if files.length < 1
        log_stuff("#{filename} is an empty directory.",$empty_log)
      elsif files.length >= 1
        files.each do |file|
          log_stuff("#{file} is below #{byte_limit} bytes.",$empty_log) if (File.size(file) < byte_limit)
        end # files.each
      end # files.length < 1
    end # if File.directory?(filename)
    # log_stuff("#{filename} is an empty directory.",$empty_log) if File.directory?(filename)
    # log_stuff("#{filename} is below #{byte_limit} bytes.",$empty_log) if (filename.size < byte_limit)
  end # Dir.glob(path)
end # find_empty_crawls

def parse_xml_files(rules_path, results_path)
  # files = []
  Dir.foreach(rules_path) do |filename| # loop for each xml file/rule
    next if filename == "." || filename == ".."
    
    begin
      filecontent = File.open("#{rules_path}#{filename}")
      ngxml = Nokogiri::XML(filecontent)
    rescue
      log_stuff("Script had trouble opening this file: #{rules_path}#{filename}",$error_log)
    ensure
      filecontent.close

    end
        
    new_path = "#{results_path}#{ngxml.xpath("//sitename[1]/@name").to_s}/"
    Dir.mkdir(new_path) unless File.exists?(new_path)
    
    docs = []
    ngxml.xpath("//sitename/docname").each do |doc|
      docs << doc.at_xpath("./@name")
    end
    
    docs.each do |name| # for every docname in sitename in file
      crawl_file_name = "#{new_path}#{name}.txt"
      crawl_file = File.open(crawl_file_name,"w") # new file or overwrite old file
      
      doc_url = ngxml.at_xpath("//docname[@name='#{name}']/url/@name")
      doc_xpath = ngxml.at_xpath("//docname[@name='#{name}']/url/@xpath") # Grabs xpath attribute from <url xpath="">
      
      ## remove when we're sure the new methods work. 
      # begin
      #   ngdoc_url = Nokogiri::HTML(open(doc_url, "User-Agent" => "Mozilla/5.0","Accept-Language" => "en-us,en;q=0.5"))
      # rescue
      #   log_stuff("Problem opening URL(404?): #{doc_url}",$error_log)
      #   next
      # end
      # 
      # tos_data = ""
      # if doc_xpath.nil?
      #   tos_data = ngdoc_url.xpath("//body").to_s
      # else 
      #   tos_data = ngdoc_url.xpath(doc_xpath.to_s).to_s
      # end
      
      tos_data = ""
      mchdoc = open_page(doc_url)
      next if mchdoc == "skip" # go to next doc if page couldn't be opened

      tos_data = scrape_page(mchdoc,doc_xpath)
      
      tos_data = format_tos(tos_data)
      
      # log_stuff("crawl data length: #{tos_data.length}","caveman.log")
      
      crawl_file.puts tos_data
      crawl_file.close
    end
        
  end
  
end

def open_page(url)
  mech = Mechanize.new { |agent| 
    agent.user_agent_alias = 'Mac FireFox'
    agent.ssl_version = 'SSLv3'
    agent.verify_mode = OpenSSL::SSL::VERIFY_NONE # less secure. Shouldn't matter for scraping.
    agent.agent.http.reuse_ssl_sessions = false
  }
  gonext = nil
  
  begin
    page = mech.get(url)
  rescue => e
    # puts "error opening page"
    log_stuff("Problem opening URL(#{e.message}): #{url}",$error_log)
    gonext = "skip"
  end
  
  # log_stuff("open page gonext: #{gonext.class}\turl: #{url}","caveman.log")
  
  return (gonext == "skip" ? gonext : page)
end

def scrape_page(mchdoc,xpath)
  if mchdoc.class == Mechanize::Page
    mchdoc.encoding = mchdoc.encoding || "UTF-8" # defaults any nil encoding to utf-8
    begin
      if xpath.nil?
        tos_data = mchdoc.search("//body").to_s
      else 
        tos_data = mchdoc.search(xpath.to_s).to_s
      end
    rescue  
      mchdoc.encoding=("UTF-8")
      if xpath.nil?
        tos_data = mchdoc.search("//body").to_s
      else 
        tos_data = mchdoc.search(xpath.to_s).to_s
      end
    end
  elsif mchdoc.class == Mechanize::File
    tos_data = mchdoc.content
    #TODO log which uris are returning Files and make sure they look okay.
  end
  
  # log_stuff("scrape page page.class: #{mchdoc.class}","caveman.log")
  
  return tos_data
end

##
# code stuff starts here :)
##

if ARGV.length == 0

  log_stuff("Beginning script!",$run_log)

  parse_xml_files(rules_path,results_path)

  #TODO mail git_modified

  log_stuff("Script finished! Check #{$error_log} for rules to fix :)",$run_log)

  git_modified

elsif ARGV[0] == "-empty"
  
  find_empty_crawls(results_path,512)

else
  
  #TODO refactor to make DRY
  
  begin
    filecontent = File.open(ARGV[0])
    ngxml = Nokogiri::XML(filecontent)
  rescue
    log_stuff("Script had trouble opening this file: #{rules_path}#{filename}",$error_log)
  ensure
    filecontent.close
  end
  
  docs = []
  ngxml.xpath("//sitename/docname").each do |doc|
    docs << doc.at_xpath("./@name")
  end
  
  docs.each do |name| # for every docname in sitename in file    
    doc_url = ngxml.at_xpath("//docname[@name='#{name}']/url/@name")
    doc_xpath = ngxml.at_xpath("//docname[@name='#{name}']/url/@xpath") # Grabs xpath attribute from <url xpath="">
    
    ### Code moved into open_page(url)

    tos_data = ""
    
    tos_data = open_page(doc_url)
    next if tos_data == "skip" # go to next doc if page couldn't be opened
    
    tos_data = scrape_page(tos_data,doc_xpath)
        
    tos_data = format_tos(tos_data)

    puts tos_data
    # crawl_file.puts tos_data
    # crawl_file.close
  end
  
end