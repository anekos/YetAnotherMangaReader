#!/usr/bin/env ruby
# vim: set fileencoding=utf-8 :

require 'gtk2'
require 'poppler'
require 'pathname'
require 'yaml'

class Size < Struct.new(:width, :height)
  def to_f
    Size.new(*self.to_a.map(&:to_f))
  end
end

class PDFDocument
  SAVE_NAMES = %W[invert splits virutal_page_number].map(&:intern)

  attr_accessor :splits
  attr_reader :filepath

  def initialize(filepath)
    @filepath = filepath.cleanpath.expand_path
    @document = Poppler::Document.new(filepath.to_s)

    @total_pages = @document.size
    @virutal_page_number = -1

    @page_map = []
    (0 .. @total_pages - 1).each {|i| @page_map[i] = i }

    @count = 1
    @invert = false
    @splits = 2
  end

  def caption
    cpn = current_page_number

    current_page =
      if splits > 1
        if @invert
          "#{cpn}-#{cpn + splits - 1}"
        else
          "#{cpn + splits - 1}-#{cpn}"
        end
      else
        "#{cpn}"
      end

    "#{filepath.basename.sub_ext('')} [#{current_page}/#{@total_pages}]"
  end

  def invert
    @invert = !@invert
  end

  def current_page_number
    @virutal_page_number + 2
  end

  def current_page_number= (n)
    n = @total_pages + n + 1 if n < 0
    n -= 2
    @virutal_page_number = n if -1 <= n and n < @page_map.size
  end

  def draw (context, context_size)
    context.save do

      page_size = nil
      (splits.downto 0).any? do
        |index|
        page_size = self.get_page_size(@virutal_page_number + index)
      end
      return unless page_size

      page_size = page_size.to_f
      context_size = context_size.to_f

      if (context_size.width.to_f / context_size.height.to_f) >= (page_size.width * splits / page_size.height)
        scale_rate = context_size.height.to_f / page_size.height
        context.scale(scale_rate, scale_rate)
        context.translate((context_size.width.to_f - scale_rate * splits * page_size.width) / scale_rate / splits, 0)
      else
        scale_rate = context_size.width.to_f / (page_size.width * splits)
        context.scale(scale_rate, scale_rate)
        context.translate(0, (context_size.height.to_f - scale_rate * page_size.height) / scale_rate / splits)
      end

      splits.times do
        |index|
        page = @virutal_page_number + (@invert ? index : splits - index)
        render_page(context, page)
        context.translate(page_size.width, 0)
      end
    end
  end

  def forward_pages (n = splits)
    if current_page_number < (@total_pages - n)
      @virutal_page_number += n
      true
    else
      false
    end
  end

  def back_pages (n = splits)
    if current_page_number > n
      @virutal_page_number -= n
      true
    else
      false
    end
  end

  def insert_blank_page_to_left
    begin
      @total_pages += 1
      @page_map.insert(@virutal_page_number + 1 , nil)
    rescue
    end
  end

  def insert_blank_page_to_right
    begin
      @total_pages += 1
      @page_map.insert(@virutal_page_number, nil)
    rescue
    end
  end

  def load (save_filepath = default_save_filepath)
    return unless data = (YAML.load_file(save_filepath) rescue {})[@filepath.cleanpath.expand_path.to_s]

    SAVE_NAMES.each do
      |name|
      current = self.instance_variable_get("@#{name}")
      self.instance_variable_set("@#{name}", data[name] || current)
    end
  end

  def save (save_filepath = default_save_filepath)
    data = (YAML.load_file(save_filepath) rescue {})
    key = @filepath.cleanpath.expand_path.to_s

    data[key] = {}
    SAVE_NAMES.each do
      |name|
      data[key][name] = self.instance_variable_get("@#{name}")
    end

    File.open(save_filepath, 'w') {|file| file.write(YAML.dump(data)) }
  end

  def get_page_size (virutal_page_number = 0)
    if ap = actual_page(virutal_page_number)
      Size.new(*@document[ap].size)
    else
      nil
    end
  end

  private

  def actual_page (virutal_page_number)
    if virutal_page_number > -1 and virutal_page_number < @page_map.size and @page_map[virutal_page_number]
      @page_map[virutal_page_number]
    else
      nil
    end
  end

  def render_page (context, virutal_page_number)
    begin
      if ap = actual_page(virutal_page_number)
        context.render_poppler_page(@document[ap])
      end
    rescue
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

  def initialize
    @count = nil
    @save_counter = 0
    @filepath = nil
    @document = nil
  end

  def open (filepath)
    @document = PDFDocument.new(filepath)
    @document.load
  end

  def start
    initialize_window
    @window.show_all
    Gtk.main
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

    page_size = @document.get_page_size
    @window.set_default_size(page_size.width * @document.splits, page_size.height)
    @window.signal_connect("destroy") do
      document.save
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

    if '0123456789'.scan(/\d/).include?(c)
      @count = 0 unless @count
      @count *= 10
      @count += c.to_i
      return true
    end

    single = @count || 1
    double = single * @document.splits

    case c
    when 'j'
      go_next_page(double)
    when 'k'
      go_previous_page(double)
    when 'J'
      @document.forward_pages(single)
    when 'K'
      @document.back_pages(single)
    when 'b'
      @document.insert_blank_page_to_right
      @document.forward_pages(double)
    when 'H'
      @document.insert_blank_page_to_left
    when 'L'
      @document.insert_blank_page_to_right
    when 'g'
      @document.current_page_number = @count ? (@count - 1) / @document.splits * @document.splits + 1 : 1
    when 'G'
      @document.current_page_number = @count || -@document.splits
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
    when 'q'
      @document.save()
      Gtk.main_quit
    else
      return
    end

    if @save_counter > 10
      @save_counter = 0
      @document.save()
    else
      @save_counter += 1
    end

    @count = nil

    repaint(event)

    true
  end

  def repaint (event)
    @drawing_area.signal_emit('expose-event', event)
    update_title
  end

  def update_title
    @window.title = @document.caption
  end

  def go_next_page (n)
    unless @document.forward_pages(n)
      next_file = YAMR.next_file(@document.filepath)
      if next_file
        @document = PDFDocument.new(next_file)
        @document.load
        @document.current_page_number = 1
      end
    end
  end

  def go_previous_page (n)
    unless @document.back_pages(n)
      previous_file = YAMR.previous_file(@document.filepath)
      if previous_file
        @document = PDFDocument.new(previous_file)
        @document.load
        @document.current_page_number = -@document.splits
      end
    end
  end
end


if ARGV.size < 1
  puts "Usage: #{$0} file"
  exit 1
end

app = YAMR.new
app.open(Pathname.new(ARGV[0]))
app.start
