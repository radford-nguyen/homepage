#!/usr/bin/env ruby

require 'rubygems'
gem 'highline'
require 'highline/import'
require 'fileutils'
require 'optparse'
require 'yaml'

CONFIG = lambda {
  cfg = {}
  cfg[:version]    = "1.0.0"
  cfg[:base_dir]   = File.expand_path File.dirname(__FILE__)
  cfg[:deploy_dir] = File.join(ENV["HOME"], "public_html")
  cfg[:help_file]  = File.join(cfg[:base_dir], "README.md")
  cfg[:archive]    = File.join(cfg[:base_dir], "_archive")
  cfg[:autogens]   = File.join(cfg[:base_dir], "_includes", "autogens")
  cfg[:themes]     = File.join(cfg[:base_dir], "_includes", "themes")
  cfg[:layouts]    = File.join(cfg[:base_dir], "_layouts")
  cfg[:posts]      = File.join(cfg[:base_dir], "_posts")
  cfg[:pages]      = File.join(cfg[:base_dir], "pages")
  cfg[:ext]        = "md"
  yaml = File.join(cfg[:base_dir], "_config.yml")
  File.open(yaml, "r") do |f|
    cfg.merge!(YAML.load(f)) { |key,old,new|
      abort "Duplicate config key '#{key}' in #{__FILE__} and #{yaml}"
    }
  end
  cfg
}.call.freeze

module Utils
  def format_date(date)
    date.strftime('%Y-%m-%d')
  end

  # Returns a path that matches the given pattern (via Dir.glob)
  # or `nil` if the pattern matches other-than 1 path
  #
  #     p = "foo/bar/*baz"
  #     one_p = get_one_path(p)
  #     puts "more than 1 path matched #{p}" if one_p.nil?
  #
  def get_one_path(path_pattern)
    files = Dir.glob(path_pattern)
    return files.length == 1 ? files[0] : nil
  end

  # Executes `system "mv src dest"` iff `dest` does not already exist, returning
  # the result.
  #
  # This is useful because this form of mv:
  #
  #     mv foo/dir bar/dir
  #
  # will create `bar/dir/dir` if `bar/dir` already exists. Using `safe_mv`
  # will prevent that from happening.
  def safe_mv(src, dest)
    if File.exists?(dest) then
      say(loud "mv request denied because destination already exists: #{dest}")
      return false
    else
      system "mv #{src} #{dest}"
    end
  end
end # module Utils

# monkey-patch String class
HighLine.colorize_strings

#
# Standardizing look-and-feel of prompt
#
module Prompt

  def loud(s)
    s.color.bold.red
  end

  def normal(s)
    s.color.cyan
  end

  def emphasize(s)
    s.color.yellow.underline
  end

  #
  # Prompts user to choose a post category, returning the choice
  # as a tuple `[c, p]`, where:
  #
  #     c = the category
  #     p = the path to the directory that holds all posts in that category
  #
  def self.choose_post_category()
    post_dirs = Dir.entries(CONFIG[:posts]).select { |x| x != '.' and x != '..' }.sort
    i = -1
    dirs_strs = post_dirs.map { |x| i+=1; "#{i}: #{x}" }

    say(emphasize "Please choose a post category by number:")
    i = ask(normal(dirs_strs.join("\n")), Integer) do |q|
      q.in = 0..post_dirs.length
    end
    cat = post_dirs[i]
    path = File.join(CONFIG[:posts], post_dirs[i])
    [cat, path]
  end

  def get_date(prompt)
    ask(emphasize(prompt) + normal(" (default current date)"), Date) do |q|
      q.default = "#{Date.today}"
    end
  end

end # module Prompt



module Posts

  class NewPost
    include Utils
    attr_accessor :dir
    attr_accessor :title
    attr_accessor :category
    attr_accessor :filename_nodate
    def initialize(dir, title, category)
      @title = title
      @category = category
      @filename_nodate = "#{title.downcase.strip.gsub(' ', '-').gsub(/[^\w-]/, '')}.#{CONFIG[:ext]}"
      @dir = dir
    end

    def write_with_newdate(newdate)
      new_post = HP::YamlDoc.new
      new_post.yaml['title'] = "#{@title}"
      new_post.yaml['category'] = "#{@category}"
      f = File.join(dir, "#{format_date(newdate)}-#{@filename_nodate}")
      abort ("File #{f} already exists. I will not overwrite it.") if File.exist?(f)
      say(normal("new #{f}"))
      new_post.write_to_file(f)
    end
  end # class NewPost

  class Post
    include Utils
    attr_accessor :date
    attr_accessor :filename_nodate
    attr_accessor :path
    def initialize(dir, filename)
      r = /(\d\d\d\d-\d\d-\d\d)-(.+)/
      @filename = filename
      @dir = dir
      @path = File.join(dir, filename)
      date_str, @filename_nodate = filename.match(r).captures
      @date = Date.parse(date_str)
    end

    def +(date_shift)
      @date += 1
    end

    def write_with_newdate(newdate)
      old = @path
      new = File.join(@dir, "#{format_date(newdate)}-#{@filename_nodate}")
      if old == new then
        say(normal("no rename of same files #{old} = #{new}"))
      else
        say(normal("rename #{old} -> #{new}"))
        File.rename(old, new)
      end
    end
  end # class Post

  # Returns a zipped list of [date, post] for all
  # the existing posts in `dir`
  #
  def self.get_posts_in(dir)
    Dir.entries(dir).select { |e|
      e =~ /\d\d\d\d-\d\d-\d\d-.*\.md$/
    }.sort.map { |filename|
      p = Post.new(dir, filename)
      d = p.date
      [d, p]
    }
  end

  # For all the posts in `dir`, reorder them according
  # to `new_positions`, which is an ordered list of
  # the posts' original positions.
  #
  # For example, to switch the 1st and 3rd posts, do:
  #
  #     Posts.reorder("posts", [2,1,0,4,5,6])
  #
  def self.reorder(dir, new_positions)
    dates, posts = get_posts_in(dir).transpose
    if posts.length != new_positions.length
      abort ("#{posts.length} posts in #{dir} != #{new_positions.length} new positions given")
    end
    posts.each_with_index do |post, i|
      post.write_with_newdate(dates[new_positions[i]])
    end
  end

  # Creates a new post and inserts it at the given `index` of
  # existing posts in `posts_dir`. All subsequent post dates
  # will be shifted to accomodate the insertion.
  def self.insert_new_post(index, posts_dir, new_post_title, new_post_category)
    dates, posts = get_posts_in(posts_dir).transpose
    dates << dates.last + 1
    index = posts.length if index > posts.length
    posts.insert(index, NewPost.new(posts_dir, new_post_title, new_post_category))
    posts.each_with_index do |post, i|
      post.write_with_newdate(dates[i])
    end
  end

end # module Posts




module HP

#
# Represents a text document with YAML front-matter
#
class YamlDoc
  attr_accessor :yaml
  attr_accessor :content
  def initialize
    @content = ""
    @yaml = {}
  end
  def self.from_file(file_path)
    abort ("given file path '#{file_path} does not exist") unless File.exist?(file_path)
    abort ("given file path '#{file_path} is not a file") unless File.file?(file_path)
    yaml = {}
    content = ""
    File.open(file_path, "r") do |f|
      yaml = YAML.load(f)
    end
    File.open(file_path, "r") do |f|
      i = 0
      lines = []
      f.each_line do |line|
        lines << line if i >= 2
        i += 1 if line.rstrip() == "---"
      end
      content = lines.join()
    end
    instance = self.new
    instance.yaml = yaml
    instance.content = content
    instance
  end
  def puts(s)
    @content += "#{s}\n"
  end
  def yaml_str()
    YAML.dump(yaml)
  end
  def to_str()
    yaml_str() + "---\n" + content
  end
  def write_to_file(filepath)
    open(filepath, 'w') do |f|
      f.puts self.to_str()
    end
  end
end # class YamlDoc

class IntArray < Array
  def self.parse(s)
    s.split(/\s+/).map { |num_str| Integer num_str }
  end
end # class IntArray

#
# Main class
#
class HP
  include Utils
  include Prompt
  include Posts

  HEADER = """
HomePage #{CONFIG[:version]}

CLI for adding new Jekyll content
""".freeze


  # Starts an interactive loop with menu options for
  # performing various homepage tasks
  def interactive()
    puts HEADER

    choose do |menu|
      puts "\nPoisons:"
      menu.shell = true
      menu.prompt = "Pick your poison> "

      menu.choice(:"new post") do
        category, dir = Prompt.choose_post_category
        dates, posts = Posts.get_posts_in(dir).transpose
        strs = posts.each_with_index.map { |p,i| "#{i}: #{p.filename_nodate}" }
        say(emphasize "Choose a position to insert the new post:")
        new_index = ask(normal(strs.join("\n")), Integer) do |q|
          q.in = 0..strs.length
        end
        title = ask(emphasize "Type the title of the new post:")
        Posts.insert_new_post(new_index, dir, title=title, category=category)
      end

      menu.choice(:"show posts") do
        category, dir = Prompt.choose_post_category
        str = Posts.get_posts_in(dir).map { |a,b| "#{a} -- #{b.filename_nodate}" }
        say(normal str.join("\n"))
      end

      menu.choice(:"reorder posts") do
        category, dir = Prompt.choose_post_category
        dates, posts = Posts.get_posts_in(dir).transpose
        strs = posts.each_with_index.map { |p,i| "#{i}: #{p.filename_nodate}" }
        say(normal "Existing positions of #{category} posts:\n#{strs.join("\n")}")
        new_positions = ask(emphasize("Enter new positions (e.g. 2 1 0)"), IntArray) do |q|
          q.validate = lambda { |s|
            IntArray.parse(s).sort == (0..strs.length-1).to_a
          }
          q.responses[:not_valid] = "New position numbers must be same as existing position numbers"
        end
        Posts.reorder(dir, new_positions)
      end

      menu.choice(:"new category") do
        new_cat = ask(emphasize "Enter new category (must be valid dir name):")
        new_dir = File.join(CONFIG[:posts], new_cat)
        if File.exist? new_dir then
          say(loud "[ERROR] #{new_dir} already exists")
        else
          say(emphasize "creating #{new_dir}")
          FileUtils.mkdir_p new_dir
        end
      end

      menu.choice(:"preview site") do
        say(normal("When done, preview doc @ http://#{ENV["HOSTNAME"]}:[port]/~#{ENV["USER"]}/index.html"))
        preview
      end

      menu.choice(:"deploy site") do
        say(normal('You are about to deploy to http://peobuild/applications/slt/sslt-doc'))
        if agree(loud "Deploying will delete current contents of #{CONFIG[:deploy_dir]}. Deploy? (y/n)")
          say(loud '[ERROR] deployment failed.') unless deploy == true
        else
          say(normal('Did not deploy'))
        end
      end

      menu.choice(:help) do
        system "cat #{CONFIG[:help_file]} | less"
      end

      menu.choice(:quit) { exit }
      
    end while true

  end


  # Archives a version container by moving its _posts content to the
  # archive folder, where it won't be used to generate the site.
  #
  # Returns `true` if successful
  def archive_version(version)
    src = File.join(CONFIG[:posts], version)
    dest = File.join(CONFIG[:archive], version)
    safe_mv(src, dest)
  end

  # Does the opposite of `archive_version`
  #
  # Returns `true` if successful
  def unarchive_version(version)
    src = File.join(CONFIG[:archive], version)
    dest = File.join(CONFIG[:posts], version)
    safe_mv(src, dest)
  end

  def new_post(dir, title=nil, category="", tags=[])

    dirname = File.join(CONFIG[:posts], "#{dir}")
    filename = File.join(filename, "index.#{CONFIG[:ext]}") if File.extname(filename) == ""
    title = File.basename(filename, File.extname(filename)).gsub(/[\W\_]/, " ").gsub(/\b\w/){$&.upcase} if title.nil?
    if File.exist?(filename)
      return false unless agree(loud "#{filename} already exists. Do you want to overwrite?")
    end
    
    FileUtils.mkdir_p File.dirname(filename)
    post = HP::YamlDoc.new
    post.yaml["layout"] = 'post'
    post.yaml["title"] = "#{title.gsub(/-/,' ')}"
    post.yaml["description"] = ""
    post.yaml["touched"] = "#{format_date(Date.today)}"
    post.yaml["category"] = category
    post.yaml["tags"] = tags
    post.puts "{% include JB/setup %}"
    puts "Creating new post: #{filename}"
    post.write_to_file(filename)
    return true
  end

  # Creates a new version container, returning `true` if successful.
  #
  #     pass = new_page("musings/java/streams.md", "Using Java 8 streams")
  #     abort("new_page failed") unless pass
  #
  # Params:
  # +path+:: TODO
  # +title+:: TODO
  def new_page(path, title=nil)

    filename = File.join(CONFIG[:pages], "#{path}")
    filename = File.join(filename, "index.#{CONFIG[:ext]}") if File.extname(filename) == ""
    title = File.basename(filename, File.extname(filename)).gsub(/[\W\_]/, " ").gsub(/\b\w/){$&.upcase} if title.nil?
    if File.exist?(filename)
      return false unless agree(loud "#{filename} already exists. Do you want to overwrite?")
    end
    
    FileUtils.mkdir_p File.dirname(filename)
    page = HP::YamlDoc.new
    page.yaml["layout"] = 'page'
    page.yaml["title"] = "#{title.gsub(/-/,' ')}"
    page.yaml["description"] = ""
    page.puts "{% include JB/setup %}"
    puts "Creating new page: #{filename}"
    page.write_to_file(filename)
    return true
  end

  # Generates the docs site and starts a server on localhost
  # to view the generated content. The process exits after
  # the server is stopped.
  def preview()
    current_dir = Dir.pwd
    Dir.chdir CONFIG[:base_dir]
    exec("./generate-site.sh --server")
    Dir.chdir current_dir
    exit
  end

  # Generates the docs site and deploys it to the official
  # server, returning `true` if successful.
  #
  # Once deployed, the release notification RSS feed is
  # updated with any new versions.
  def deploy()
    deploy_dir = CONFIG[:deploy_dir]
    current_dir = Dir.pwd
    Dir.chdir CONFIG[:base_dir]
    say('Generating html...')
    pass = system "./generate-site.sh"
    unless not pass
      say("Deleting #{deploy_dir}")
      system "rm -rf #{deploy_dir}"
      say("Copying site to #{deploy_dir}")
      pass = system "cp -rip #{CONFIG['destination']} #{deploy_dir}"
    end
    Dir.chdir current_dir
    return pass
  end

  # Updates a version container with the given release date,
  # also updating any JIRA ticket and dependency information
  # in the process. Returns `true` if successful.
  #
  #     pass = update("1.2.3", Date.parse("2010-01-31"))
  #     abort("failed version update") unless pass
  #
  # Params:
  # +version+:: the version container to update
  # +date+:: the release date for this version
  def update(version, date)

    unless Versions.exists? version
      say(loud "[ERROR] Version: #{version} is not a current version: #{versions.join(', ')}")
      return false
    end

    date_str = format_date(date)

    # 1
    say(normal("Saving current breaking-changes content for later"))
    slt_breaking_path = get_one_path("#{CONFIG[:posts]}/#{version}/slt/release-notes/*breaking-changes.md")
    ubi_breaking_path = get_one_path("#{CONFIG[:posts]}/#{version}/ubi/release-notes/*breaking-changes.md")

    if slt_breaking_path.nil? or ubi_breaking_path.nil?
      say(loud "[ERROR] Breaking changes posts are messed up in #{version}. Pull a new clean Doc and try again")
      return false
    end

    ubi_breaking = HP::YamlDoc.from_file(ubi_breaking_path)
    slt_breaking = HP::YamlDoc.from_file(slt_breaking_path)

    ubi_breaking_data = ubi_breaking.content
    slt_breaking_data = slt_breaking.content

    # 2
    say(normal("Wiping all generated content for version container #{version}"))
    system "rm -rf #{CONFIG[:posts]}/#{version}/slt/release-notes/*"
    system "rm -rf #{CONFIG[:posts]}/#{version}/ubi/release-notes/*"
    system "rm -rf #{CONFIG[:posts]}/#{version}/slt/userguide/*index.#{CONFIG[:ext]}"
    system "rm -rf #{CONFIG[:posts]}/#{version}/ubi/userguide/*index.#{CONFIG[:ext]}"

    # 3
    say(normal("Regenerating version container #{version}"))
    status = new_version(version, date)
    unless status
      say(loud "[ERROR] in the updating of meta-data for version: #{version}")
      return false 
    end

    # 4
    say(normal("Inserting saved breaking-changes content into newly-updated breaking-changes pages"))
    slt_breaking_path = get_one_path("#{CONFIG[:posts]}/#{version}/slt/release-notes/*breaking-changes.#{CONFIG[:ext]}")
    ubi_breaking_path = get_one_path("#{CONFIG[:posts]}/#{version}/ubi/release-notes/*breaking-changes.#{CONFIG[:ext]}")

    if slt_breaking_path.nil? or ubi_breaking_path.nil?
      say(loud "[ERROR] Breaking changes posts are messed up in #{version}. Pull a new clean Doc and try again")
      return false
    end

    ubi_breaking = HP::YamlDoc.from_file(ubi_breaking_path)
    slt_breaking = HP::YamlDoc.from_file(slt_breaking_path)
    ubi_breaking.content = ubi_breaking_data 
    slt_breaking.content = slt_breaking_data 
    ubi_breaking.write_to_file(ubi_breaking_path)
    slt_breaking.write_to_file(slt_breaking_path)

    # 5
    say(normal("updating the release date on manually-created userguide files"))
    ['slt', 'ubi'].each do |client|
      userguide_pages = Dir.glob("#{CONFIG[:posts]}/#{version}/#{client}/userguide/9999-*.#{CONFIG[:ext]}")
      userguide_pages.each do |f|
        doc = HP::YamlDoc.from_file(f)
        doc.yaml["released"] = date_str
        doc.write_to_file(f)
      end
    end

    # ???

    # profit
    return true
  end

  # Copies all manually-created userguide files from
  # one version to another, replacing any files that
  # may already exist.
  #
  # Returns `true` if successful.
  #
  #     pass = copy_userguide("1.2.3", "2.0.0")
  #     abort("userguide copy failed") if not pass
  #
  def copy_userguide(from_version, to_version)
    [from_version, to_version].each do |version|
      unless Versions.exists? version
        say(loud "[ERROR] Version: #{version} is not a current version: #{Versions.current.join(', ')}")
        return false
      end
    end
    
    ['slt', 'ubi'].each do |client|
      # get the autogenerate file so we can use its header data
      autof = get_one_path("#{CONFIG[:posts]}/#{to_version}/#{client}/userguide/*index.md")
      if autof.nil?
        puts "Error finding autogenerated userguide file for #{client} version '#{to_version}'"
        return false
      end
      autodoc = HP::YamlDoc.from_file(autof)
      
      userguides_to_copy = Dir.glob("#{CONFIG[:posts]}/#{from_version}/#{client}/userguide/9999-*.md")
      userguides_to_copy.each do |f|
        doc = HP::YamlDoc.from_file(f)
        doc.yaml["type"] = autodoc.yaml["type"]
        doc.yaml["version"] = autodoc.yaml["version"]
        doc.yaml["released"] = autodoc.yaml["released"]
        doc.yaml["category"] = autodoc.yaml["category"]
        newfile = "#{CONFIG[:posts]}/#{to_version}/#{client}/userguide/#{File.basename(f)}"
        puts "Writing new userguide file: #{newfile}"
        doc.write_to_file(newfile)
      end
    end
    return true
  end

  # Generates a version container for the given version
  # and release date, returning `true` if successful.
  #
  #     pass = generate_version_container("1.2.3", Date.today)
  #     exit(false) if not pass
  #
  def generate_version_container(version, date)
    abort("rake aborted: '#{CONFIG[:posts]}' directory not found.") unless FileTest.directory?(CONFIG[:posts])
    
    # YAML lib does not like the HighLine::str
    version = "#{version}"

    def get_breaking_filename_for(client)
      date = client.date + 1
      date_fmt = format_date(date)
      File.join(client.category, "#{date_fmt}-breaking-changes.#{CONFIG[:ext]}")
    end

    date_fmt = format_date(date)
    types = ["release-notes", "userguide"]
    CONFIG[:clients].each do |client|
      client.date = date
      client.version = version
      types.each do |type|
        client.category = File.join(version, client.short_name, type)
        title = "#{client.full_name}-#{version} #{type}"

        # make the initial breaking-changes file
        if type == 'release-notes'
          breakfile = File.join(CONFIG[:posts], get_breaking_filename_for(client))
          unless not File.exist?(breakfile)
            say(loud "[ERROR] #{breakfile} already exists")
            return false
          end
          FileUtils.mkdir_p File.dirname(breakfile)
          puts "Creating new file: #{breakfile}"
          HP::BreakingChangesDoc.new(client).write_to_file(breakfile)
        end

        filename = File.join(CONFIG[:posts], client.category, "#{format_date(client.date)}-index.#{CONFIG[:ext]}")
        unless not File.exist?(filename)
          say(loud "[ERROR] #{filename} already exists")
          return false
        end
        post = HP::YamlDoc.new
        post.yaml["layout"] = type
        post.yaml["type"] = type
        post.yaml["title"] = "#{title.gsub(/-/,' ')}"
        post.yaml["publish"] = "true" if type == "release-notes"
        post.yaml["description"] = ""
        post.yaml["tags"] = [type, client.short_name]
        post.yaml["category"] = client.category
        post.yaml["client"] = client.short_name
        post.yaml["projname"] = client.full_name
        post.yaml["repo"] = client.repo
        post.yaml["repo_browse"] = client.repo_browse
        post.yaml["version"] = version
        post.yaml["released"] = date_fmt
        post.puts "{% include JB/setup %}"
        if type == "userguide"
          post.puts "{% include snippets/default-userguide-intro.md %}"
        elsif type == "release-notes"
          post.puts ""
          post.puts "## Release Info"
          post.puts ""
          post.puts "- **Version:** #{version}"
          post.puts "- **Release Date:** #{date_fmt}"
          post.puts "- **Blessed Repository:** [#{client.repo_browse}](#{client.repo_browse})"
          post.puts ""
          post.puts "## Dependencies"
          post.puts ""
          post.puts "<pre>"
          post.puts "{% include autogen/#{version}/#{client.short_name}-dependencies.txt %}"
          post.puts "</pre>"
          post.puts ""
          post.puts "## Resolved Issues"
          post.puts ""
          post.puts "{% include autogen/#{version}/#{client.short_name}-issues.md %}"
        end
        FileUtils.mkdir_p File.dirname(filename)
        puts "Creating new file: #{filename}"
        post.write_to_file(filename)
      end
    end
    return true
  end # generate_version_container 

end # class HP

end # module HP


if __FILE__ == $0
then
  include Prompt
  HP::HP.new.interactive()
end
