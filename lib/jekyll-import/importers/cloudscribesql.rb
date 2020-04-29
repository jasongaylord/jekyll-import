# frozen_string_literal: false

module JekyllImport
  module Importers
    class CloudScribeSql < Importer
      def self.require_deps
        JekyllImport.require_with_fallback(%w(
          rubygems
          fileutils
          safe_yaml
          unidecode
          tiny_tds
        ))
      end

      def self.specify_options(c)
        c.option "database",       "--database DB",       "Database name (default: '')"
        c.option "user",           "--user USER",           "Database user name (default: '')"
        c.option "password",       "--password PW",         "Database user's password (default: '')"
        c.option "host",           "--host HOST",           "Database host name (default: 'localhost')"
        c.option "port",           "--port PORT",           "Database port number (default: '')"
        c.option "blog_id",        "--blog_id GUID",        "The GUID of the blog (default: '')"
        c.option "azure",          "--azure",               "Whether the DB is in Azure (default: true)"
        c.option "clean_entities", "--clean_entities",      "Whether to clean entities (default: true)"
        c.option "comments",       "--comments",            "Whether to import comments (default: true)"
        c.option "categories",     "--categories",          "Whether to import categories (default: true)"
        c.option "extension",      "--extension"            "Post extension (default: 'html')"
      end

      # Main migrator function. Call this to perform the migration.
      #
      # database::  The name of the database
      # user::    The database user name
      # password::    The database user's password
      # host::    The address of the MSSQL database host. Default: 'localhost'
      # port::    The port number of the MSSQL database. Default: '1433'
      #
      # Supported options are:
      #
      # :blog_id::        The GUID of the blog you'd like to export. By default, all blogs are included.
      #                   Default: ''
      # :clean_entities:: If true, convert non-ASCII characters to HTML
      #                   entities in the posts, comments, titles, and
      #                   names. Requires the 'htmlentities' gem to
      #                   work. Default: true.
      # :comments::       If true, migrate post comments too. Comments
      #                   are saved in the post's YAML front matter.
      #                   Default: true.
      # :categories::     If true, save the post's categories in its
      #                   YAML front matter. Default: true.
      # :extension::      Set the post extension. Default: "html"

      def self.process(opts)
        options = {
          :user           => opts.fetch("user", ""),
          :pass           => opts.fetch("password", ""),
          :host           => opts.fetch("host", "localhost"),
          :port           => opts.fetch("port", "1433"),
          :database       => opts.fetch("database", ""),
          :blog_id        => opts.fetch("blog_id", ""),
          :azure          => opts.fetch("azure", true),
          :clean_entities => opts.fetch("clean_entities", true),
          :comments       => opts.fetch("comments", true),
          :categories     => opts.fetch("categories", true),
          :extension      => opts.fetch("extension", "html"),
        }

        if options[:clean_entities]
          begin
            require "htmlentities"
          rescue LoadError
            warn "Could not require 'htmlentities', so the " \
                        ":clean_entities option is now disabled."
            options[:clean_entities] = false
          end
        end

        FileUtils.mkdir_p("_posts")

        client = TinyTds::Client.new username: options[:user], password: options[:password], host: options[:host],
            port: options[:port], database: options[:database], azure: options[:azure]

        tsql = "SELECT 
                  posts.Id            AS 'id',
                  posts.Title         AS 'title',
                  posts.Slug          AS 'slug',
                  posts.PubDate       AS 'date',
                  posts.IsPublished   As 'ispublished',
                  posts.Categories    As 'categories',
                  posts.Content       AS 'content',
                  (select count(*) from cs_PostComment where PostEntityId = posts.Id and IsApproved = 1) AS 'comment_count',
                  users.DisplayName   AS 'author',
                  users.Email         AS 'author_email'
                FROM cs_Post AS 'posts'
                  LEFT JOIN cs_User as 'users'
                    ON posts.Author = users.Email
                "

        if options[:blog_id] && !options[:blog_id].empty?
          bi = options[:blog_id]
          tsql << "WHERE BlogId like '#{bi}'"
        end

        result = client.execute(tsql)

        result.each do |post|
          process_post(post, client, options)
        end
      end

      def self.process_post(post, client, options)
        extension = options[:extension]

        title = post[:title]
        title = clean_entities(title) if options[:clean_entities]

        slug = post[:slug]
        slug = sluggify(title) if !slug || slug.empty?

        date = post[:date] || Time.now
        name = format("%02d-%02d-%02d-%s.%s", date.year, date.month, date.day, slug, extension)
        content = post[:content].to_s
        content = clean_entities(content) if options[:clean_entities]

        categories = []
        if options[:categories]
          if post[:categories] && !post[:categories].empty
            categories = post[:categories].split(',')
          end
        end

        comments = []

        if options[:comments] && post[:comment_count].to_i.positive?
          tsql2 =
            "SELECT
               id           AS 'id',
               author       AS 'author',
               email        AS 'author_email',
               website      AS 'author_url',
               pubdate      AS 'date',
               content      AS 'content'
             FROM cs_PostComment
             WHERE
               PostEntityId = '#{post[:id]}' AND
               IsApproved = 1"

          result = client.execute(tsql2)

          result.each do |comment|
            comcontent = comment[:content].to_s
            comcontent.force_encoding("UTF-8") if comcontent.respond_to?(:force_encoding)
            comcontent = clean_entities(comcontent) if options[:clean_entities]

            comments << {
              "id"           => comment[:id].to_i,
              "author"       => comment[:author].to_s,
              "author_email" => comment[:author_email].to_s,
              "author_url"   => comment[:author_url].to_s,
              "date"         => comment[:date].to_s,
              "content"      => comcontent,
            }
          end

          comments.sort! { |a, b| a["id"] <=> b["id"] }
        end

        # Get the relevant fields as a hash, delete empty fields and
        # convert to YAML for the header.
        data = {
          "layout"        => "post",
          "status"        => post[:ispublished].to_i == 1 ? "post" : "draft",
          "published"     => post[:ispublished].to_i == 0 ? nil : (post[:status].to_s == "publish"),
          "title"         => title.to_s,
          "author"        => {
            "display_name" => post[:author].to_s,
            "login"        => post[:author_email].to_s,
            "email"        => post[:author_email].to_s,
          },
          "author_login"  => post[:author_email].to_s,
          "author_email"  => post[:author_email].to_s,
          "cloudscribe_id"  => post[:id],
          "cloudscribe_slug" => post[:slug].to_s,
          "date"          => date.to_s,
          "categories"    => options[:categories] ? categories : nil,
          "tags"          => nil,
          "comments"      => options[:comments] ? comments : nil,
        }.delete_if { |_k, v| v.nil? || v == "" }.to_yaml

        if post[:type] == "page"
          filename = page_path(post[:id], page_name_list) + "index.#{extension}"
          FileUtils.mkdir_p(File.dirname(filename))
        elsif post[:status] == "draft"
          filename = "_drafts/#{slug}.md"
        else
          filename = "_posts/#{name}"
        end

        # Write out the data and content to file
        File.open(filename, "w") do |f|
          f.puts data
          f.puts "---"
          f.puts Util.wpautop(content)
        end
      end

      def self.clean_entities(text)
        text.force_encoding("UTF-8") if text.respond_to?(:force_encoding)
        text = HTMLEntities.new.encode(text, :named)
        # We don't want to convert these, it would break all
        # HTML tags in the post and comments.
        text.gsub!("&amp;", "&")
        text.gsub!("&lt;", "<")
        text.gsub!("&gt;", ">")
        text.gsub!("&quot;", '"')
        text.gsub!("&apos;", "'")
        text.gsub!("&#47;", "/")
        text
      end

      def self.sluggify(title)
        title.to_ascii.downcase.gsub(%r![^0-9A-Za-z]+!, " ").strip.tr(" ", "-")
      end
    end
  end
end