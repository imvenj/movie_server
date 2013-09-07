#!/usr/bin/env ruby
#encoding = UTF-8
require "rubygems"
require "sinatra"
require "json"
require "yaml"
require "shellwords"
require "date"
require "fileutils"
include FileUtils

class AppConfig
  def initialize
    @vars = YAML.load(open(File.join(File.dirname(__FILE__), 'server_conf.yml')).read)
  end
  
  def public_folder
    @vars["public_folder"]
  end
  
  def lx_command
    @vars["lixian_command"]
  end
  
  def max_pic_size
    @vars["max_pic_size"].to_i * 1024
  end
  
  def relative_folders
    @vars["relative_folders"]
  end
  
  def default_sort?
    @vars["default_sort_order"]
  end
  
  def basic_auth_enabled?
    @vars["enable_basic_auth"]
  end
  
  def username
    @vars["auth"][0]
  end
  
  def password
    @vars["auth"][1]
  end
  
end

config = AppConfig.new

helpers do
  def torrent_with_pic(pic)
    pic_name = File.basename(pic, ".jpg")
    pic_dir = File.dirname(pic)
    tr_name_1 = File.join(pic_dir, "#{pic_name}.torrent")
    frags = pic.split("_");frags.pop
    tr_name_2 = "#{frags.join("_")}.torrent"
    puts tr_name_1
    if File.exists?(tr_name_1)
      return tr_name_1
    elsif File.exists?(tr_name_2)
      return tr_name_2
    else
      tr_base = pic_name.gsub(/(201\d_\d\d-\d\d?-?\d?)\./, '\1_')
      tr_name = File.join(pic_dir, "#{tr_base}.torrent")
      if File.exists?(tr_name)
        return tr_name
      else
        return nil
      end
    end
  end
  
  def protected!
    return if authorized?
    headers['WWW-Authenticate'] = 'Basic realm="Restricted Area"'
    halt 401, {status: "Not authorized"}.to_json
  end

  def authorized?
    @auth ||=  Rack::Auth::Basic::Request.new(request.env)
    config = AppConfig.new
    @auth.provided? and @auth.basic? and @auth.credentials and @auth.credentials == [config.username, config.password]
  end
end

def date_with_pic(pic)
  pic.match(/(201\d_\d\d-\d\d?)/).to_a[1] || pic.match(/(\[\d\-\d\d\]最新BT合(集)?)/).to_a[1]
end

set :public_folder, config.public_folder

before do
  content_type 'text/json'
  protected! if config.basic_auth_enabled?
end

# Movie live cast
get "/" do
  movies = []
  cd config.public_folder do
    movies = Dir["**/*"].select { |f| ["mp4", "m4v", "mov"].include?(f.split(".").last.downcase) and !File.directory?(f) }.sort.to_json
  end
  movies
end

get "/info/:file" do
  f = params[:file]
  if f =~ /%252F/  # Linux server
    f.gsub!("%252F", "/")
  else             # OS X server
    f.gsub!("%2F", "/")
  end
  cd config.public_folder do
    if File.exists?(f)
      stat = File.stat(File.join(config.public_folder, f))
      return {file: f, size: stat.size, atime: stat.atime, mtime: stat.mtime, ctime: stat.ctime, exist: true}.to_json
    else
      return {exist: false}.to_json
    end
  end
end

delete "/remove/:file" do
  f = params[:file]
  if f =~ /%252F/  # Linux server
    f.gsub!("%252F", "/")
  else             # OS X server
    f.gsub!("%2F", "/")
  end
  cd config.public_folder do
    if File.exists?(f)
      %x[rm -f #{f.shellescape}]
    end
  end
  {status: "done"}.to_json
end

# Torrents related
get "/torrents" do
  datelist = []
  folders = config.relative_folders
  cd config.public_folder do
    cd folders[0] do
      regex = /(\d{4}\/\d{2}-\d{1,2})(-\d)?\/1\/$/
      selected = open(".finished").readlines.to_a.select { |u| u.strip =~ regex }
      datelist = selected.map { |u| regex.match(u)[1].gsub("/", "_") }.sort.reverse
    end
    cd folders[1] do
      list = Dir["**"].select{ |f| !(["SyncArchive", "tu.rb"].include?(f)) }.sort_by do |x|
        m = x[1...x.index(']')].split("-")
        [m.length, *m.map{|a|a.to_i}]
      end.reverse
      if config.default_sort?
        datelist = list + datelist
      else
        datelist += list
      end
    end
  end
  return datelist.to_json
end

get "/search/:keyword" do
  keyword = params[:keyword]
  pics = []
  max_pic_size = config.max_pic_size
  folders = config.relative_folders
  cd config.public_folder do
    if keyword.index("[")
      cd File.join(folders[1], keyword) do
        pics = Dir["*"].select do |f|
          if ["jpg", "gif", "png", "bmp", "jpeg"].index(f.split(".").last.downcase)
            File.stat(f).size < max_pic_size
          end
        end
        pics.map!{ |f| File.join(folders[1], keyword, f) }
      end
    else
      cd folders[0] do
        pics = Dir["**/*#{keyword}*"].select{ |f| ["jpg", "jpeg"].index(f.split(".").last.downcase) }.map{|f| File.join(folders[0], f)}
      end
    end
  end
  return pics.sort.to_json
end

get "/lx/:file/:async" do
  f = params[:file]
  if f =~ /%252F/  # Linux server
    f.gsub!("%252F", "/")
  else             # OS X server
    f.gsub!("%2F", "/")
  end
  lx_command = config.lx_command
  cd config.public_folder do
    if params[:async] == "1"
      fork {
        exec "#{lx_command} add #{torrent_with_pic f}"
      }
      return {status: "done"}.to_json
    elsif params[:async] == "0"
      result = %x[#{lx_command} add #{torrent_with_pic f}]
      if result =~ /completed/
        status = "completed"
      elsif result =~ /waiting/
        status = "waiting"
      elsif result =~ /downloading/
        status = "downloading"
      else
        status = "failed or unknown"
      end
      return {status: status}.to_json
    end
  end
end
