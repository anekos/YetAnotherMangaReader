#!/usr/bin/env ruby
# vim: set fileencoding=utf-8 :

require 'gtk2'
require 'poppler'
require 'pathname'
require 'yaml'
require 'time'

class Size < Struct.new(:width, :height)
  def to_f
    Size.new(*self.to_a.map(&:to_f))
  end
end

class ReadTimeLog < Struct.new(:opened, :closed)
  def self.make (page)
    self.new(ReadTime.now(page), nil)
  end

  def set_closed (page)
    self.closed = ReadTime.now(page)
  end
end

class ReadTime < Struct.new(:time, :page)
  def self.now (page)
    self.new(DateTime.now, page)
  end
end

module Key
  Up    = 65362
  Down  = 65364
  Left  = 65361
  Right = 65363
end

class PDFDocument
  SAVE_NAMES = %W[inverted splits page_index marks times page_number_delta].map(&:intern)

  attr_accessor :splits, :page_index, :inverted, :page_number_delta
  attr_reader :filepath, :loaded

  def initialize(filepath)
    @filepath = filepath.cleanpath.expand_path
    @document = Poppler::Document.new(filepath.to_s)

    @total_pages = @document.size
    @page_index = 0

    @page_map = []
    (0 .. @total_pages - 1).each {|i| @page_map[i] = i }

    @count = 1
    @inverted = false
    @splits = 2
    @loaded = false
    @marks = {}
    @times = []
    @page_number_delta = nil
  end

  def open
    self.load
    @times << ReadTimeLog.make(self.page_number)
  end

  def close
    @times.last.set_closed(self.page_number)
    self.save
  end

  def caption
    pn = page_number

    current_pages =
      if splits > 1
        if @inverted
          [pn, pn + splits - 1]
        else
          [pn + splits - 1, pn]
        end
      else
        [pn]
      end

    delta =
      if self.page_number_delta
        current_pages.map {|it| it - self.page_number_delta } .join('-') + '/'
      else
        ''
      end

    "#{filepath.basename.sub_ext('')} [#{delta}#{current_pages.join('-')}/#{@total_pages}]"
  end

  def invert
    @inverted = !@inverted
  end

  def page_number
    self.page_index + 1
  end

  def page_number= (n)
    self.page_index = n - 1
  end

  def real_page_number= (n)
    if d =  self.page_number_delta
      self.page_number = n + d
    else
      self.page_number = n
    end
  end

  def real_page_number
    if d =  self.page_number_delta
      self.page_number - d
    else
      self.page_number
    end
  end

  def page_index= (n)
    n = @total_pages + n if n < 0
    @page_index = n if 0 <= n and n < @total_pages
    @page_index
  end

  def draw (context, context_size)
    context.save do

      page_size = nil
      ((splits - 1).downto 0).any? do
        |index|
        page_size = self.get_page_size(@page_index + index)
      end
      return unless page_size

      page_size = page_size.to_f
      context_size = context_size.to_f

      if (context_size.width.to_f / context_size.height.to_f) >= (page_size.width * splits / page_size.height)
        scale_rate = context_size.height.to_f / page_size.height
        context.scale(scale_rate, scale_rate)
        context.translate((context_size.width.to_f - scale_rate * splits * page_size.width) / scale_rate / 2, 0)
      else
        scale_rate = context_size.width.to_f / (page_size.width * splits)
        context.scale(scale_rate, scale_rate)
        context.translate(0, (context_size.height.to_f - scale_rate * page_size.height) / scale_rate / 2)
      end

      splits.times do
        |index|
        page = @page_index + (@inverted ? index : splits - index - 1)
        render_page(context, page)
        context.translate(page_size.width, 0)
      end
    end
  end

  def forward_pages (n = splits)
    pi = self.page_index + n
    if (0 ... @total_pages) === pi
      self.page_index = pi
      true
    else
      false
    end
  end

  def back_pages (n = splits)
    pi = self.page_index - n
    if (0 ... @total_pages) === pi
      self.page_index = pi
      true
    else
      false
    end
  end

  def insert_blank_page_to_left
    begin
      @total_pages += 1
      @page_map.insert(@page_index + 1 , nil)
    rescue
    end
  end

  def insert_blank_page_to_right
    begin
      @total_pages += 1
      @page_map.insert(@page_index, nil)
    rescue
    end
  end

  def first_blank_page= (v)
    if v and !self.first_blank_page
      @total_pages += 1
      @page_map.insert(0, nil)
    elsif !v and self.first_blank_page
      @total_pages -= 1
      @page_map.delete_at(0)
    end
    self.first_blank_page
  end

  def first_blank_page
    !@page_map.first
  end

  def toggle_first_blank_page
    self.first_blank_page = !self.first_blank_page
  end

  def load (save_filepath = default_save_filepath)
    return unless data = (YAML.load_file(save_filepath) rescue {})[@filepath.cleanpath.expand_path.to_s]

    SAVE_NAMES.each do
      |name|
      current = self.instance_variable_get("@#{name}")
      self.instance_variable_set("@#{name}", data[name] || current)
    end

    (data[:blank_pages] || []).each do
      |page|
      @page_map.insert(page, nil)
    end

    @loaded = true
    return true
  end

  def save (save_filepath = default_save_filepath)
    data = (YAML.load_file(save_filepath) rescue {})
    key = @filepath.cleanpath.expand_path.to_s

    data[key] = {}
    SAVE_NAMES.each do
      |name|
      data[key][name] = self.instance_variable_get("@#{name}")
    end

    blank_pages = []
    @page_map.each_with_index {|v, k| blank_pages << k unless v }
    data[key][:blank_pages] = blank_pages

    File.open(save_filepath, 'w') {|file| file.write(YAML.dump(data)) }
  end

  def get_page_size (index, skip_blank_page = false)
    begin
      if ap = actual_page(index)
        return Size.new(*@document[ap].size)
      end
      index += 1
    end while skip_blank_page and index < @total_pages
    nil
  end

  def mark (c)
    @marks[c] = self.page_index
  end

  def jump (c)
    if index = @marks[c]
      self.page_index = index
      true
    else
      false
    end
  end

  private

  def actual_page (index)
    if (0 ... @total_pages) === index
      @page_map[index]
    else
      nil
    end
  end

  def render_page (context, index)
    begin
      if ap = actual_page(index)
        context.render_poppler_page(@document[ap])
      end
    rescue => e
      puts e
    end
  end

  def default_save_filepath
    Pathname.new(ENV['HOME']) + '.yamr.saves'
  end
end

class YAMR
  def self.next_file (filepath)
    es, i = self.get_dir_info(filepath)
    return nil unless i
    i += 1
    i < es.size ? es[i] : es.first
  end

  def self.previous_file (filepath)
    es, i = self.get_dir_info(filepath)
    return nil unless i
    i -= 1
    i >= 0 ? es[i] : es.last
  end

  def self.get_dir_info (filepath)
    dir = filepath.dirname
    es = dir.entries.select {|it| /\A\.pdf\Z/i === it.extname } .sort.map {|it| (dir + it).cleanpath.expand_path }
    i = es.index(filepath)
    return es, i
  end

  attr_reader :events

  def initialize
    @count = nil
    @save_counter = 0
    @filepath = nil
    @document = nil
    @events = {}
    @do_write_to_png = false

    rcfile_path = Pathname.new(ENV['HOME']) + '.yamrrc'
    if rcfile_path.exist?
      rcfile = RCFile.new(self)
      rcfile.instance_eval(File.read(rcfile_path))
    end
  end

  def open (filepath)
    @document.close if @document
    @document = PDFDocument.new(filepath)
    @document.open
    call_event(:on_open, @document)
  end

  def start
    initialize_window
    @window.show_all
    Gtk.main
  end

  def call_event (name, *args)
    return unless event = @events[name.intern]
    event.call(*args)
  end

  private

  def initialize_window
    @window = Gtk::Window.new

    @window.signal_connect('key-press-event', &self.method(:on_key_press_event))

    @drawing_area = Gtk::DrawingArea.new
    @window.add(@drawing_area)
    @drawing_area.signal_connect('expose-event', &self.method(:on_expose_event))

    @window.set_events(Gdk::Event::BUTTON_PRESS_MASK)
    @drawing_area.signal_connect('scroll-event', &self.method(:on_scroll_event))
    @window.signal_connect('scroll-event', &self.method(:on_scroll_event))

    page_size = @document.get_page_size(0, true)
    @window.set_default_size(page_size.width * @document.splits, page_size.height)
    @window.signal_connect("destroy") do
      document.close
      Gtk.main_quit
      false
    end

    update_title
  end

  def on_expose_event (widget, event)
    context = widget.window.create_cairo_context
    x, y, w, h = widget.allocation.to_a

    #背景の塗り潰し
    context.set_source_rgb(1, 1, 1)
    context.rectangle(0, 0, w, h)
    context.fill

    @document.draw(context, Size.new(w, h))

    if @do_write_to_png
      @do_write_to_png = false
        png_filepath = (Pathname.new(Dir.tmpdir) + "yamr-out-#{Time.now.strftime('%Y-%m-%d_%H:%M:%S')}.png").to_s

        context.target.write_to_png(png_filepath.to_s)

        ext = context.text_extents(png_filepath)
        margin = 5

        context.set_source_color('blue')
        context.stroke do
          context.rectangle(20, 20, ext.width + margin * 2, ext.height + margin * 2)
        end

        context.set_source_color('red')
        context.move_to(20 + margin, 20 + ext.height + margin)
        context.show_text(png_filepath.to_s)
    end

    true
  end

  def on_scroll_event (widget, event)
    case event.direction
    when Gdk::EventScroll::Direction::DOWN
      go_next_page(@document.splits)
    when Gdk::EventScroll::Direction::UP
      go_previous_page(@document.splits)
    end
    repaint(event)
  end

  def on_key_press_event (widget, event)
    c = event.keyval.chr rescue nil

    catch (:main) do
      if @next_on_press
        @next_on_press.call(c)
        @next_on_press = nil
        break :main
      end

      if '0123456789'.scan(/\d/).include?(c)
        @count = 0 unless @count
        @count *= 10
        @count += c.to_i
        return true
      end

      single = @count || 1
      double = single * @document.splits

      case c
      when nil
        case event.keyval
        when Key::Up, Key::Left
          go_previous_page(double)
        when Key::Down, Key::Right
          go_next_page(double)
        end
      when 'j'
        go_next_page(double)
      when 'k'
        go_previous_page(double)
      when 'J'
        @document.forward_pages(single)
      when 'K'
        @document.back_pages(single)
      when 'b'
        @document.toggle_first_blank_page
      when 'H'
        @document.insert_blank_page_to_left
      when 'L'
        @document.insert_blank_page_to_right
      when 'g'
        @document.page_number = @count ? (@count - 1) / @document.splits * @document.splits + 1 : 1
      when 'G'
        @document.page_number = @count || -@document.splits + 1
      when 'v'
        @document.invert()
      when 'r'
        @document.load()
      when 'w'
        @document.save()
      when 's'
        if @count
          @document.splits = @count if (1 .. 10) === @count
        else
          @document.splits = @document.splits > 1 ? 1 : 2
        end
      when 'S'
        @do_write_to_png = true
      when 'q'
        @document.close
        Gtk.main_quit
      when "'"
        @next_on_press = proc {|c| @document.jump(c) }
      when 'm'
        @next_on_press = proc {|c| @document.mark(c) }
      when 'd'
        @document.page_number_delta = @document.page_number - single
      when 'D'
        @document.page_number_delta = nil
      when 'p'
        @document.real_page_number = single
      else
        return false
      end

      if @save_counter > 10
        @save_counter = 0
        @document.save()
      else
        @save_counter += 1
      end
    end

    @count = nil
    repaint(event)

    true
  end

  def repaint (event)
    @drawing_area.signal_emit('expose-event', event)
    update_title
  end

  def update_title (title = @document.caption)
    @window.title = title
  end

  def go_next_page (n)
    unless @document.forward_pages(n)
      @document.save
      next_file = YAMR.next_file(@document.filepath)
      if next_file
        self.open(next_file)
        @document.page_number = 1
      end
    end
  end

  def go_previous_page (n)
    unless @document.back_pages(n)
      @document.save
      previous_file = YAMR.previous_file(@document.filepath)
      if previous_file
        self.open(previous_file)
        @document.page_number = -@document.splits
      end
    end
  end
end

class RCFile
  def initialize (app)
    @app = app
  end

  def on_open (&block)
    @app.events[:on_open] = block
  end
end


if ARGV.size < 1
  puts "Usage: #{$0} file"
  exit 1
end

app = YAMR.new
app.open(Pathname.new(ARGV[0]))
app.start
