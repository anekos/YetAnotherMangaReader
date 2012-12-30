#!/usr/bin/env ruby

require 'gtk2'
require 'poppler'
require 'pathname'
require 'yaml'

class PDFDocument
  attr_accessor :splits

  def initialize(pdf_filename, blank_page_filename=nil)
    if blank_page_filename
    end

    @pdf_filename = pdf_filename
    @document = Poppler::Document.new(pdf_filename.to_s)

    total_page = @document.size

    @virtual_page = -1

    @page_map = []
    (0..total_page-1).each { |i|
      @page_map[i] = i
    }

    @count = 1
    @invert = false
    @splits = 2

  end

  def invert
    @invert = !@invert
  end

  def actual_page(virtual_page)
      if virtual_page > -1 && virtual_page < @page_map.size && @page_map[virtual_page]
        return @page_map[virtual_page]
      end
      return nil
  end

  def page_size(virtual_page=0)
    actual_page = actual_page(virtual_page)
    if actual_page
      return @document[actual_page].size
    end
    return nil
  end

  def render_page(context, virtual_page)
    begin
      actual_page = actual_page(virtual_page)
      if actual_page
        context.render_poppler_page(@document[actual_page])
      end
    rescue
    end
  end

  def draw(context, context_width, context_height)
    context.save do

      page_size = nil
      (splits.downto 0).any? do
        |index|
        page_size = self.page_size(@virtual_page + index)
      end
      return unless page_size

      page_width, page_height = page_size.map { |e| e.to_f}

      context_width = context_width.to_f
      context_height = context_height.to_f

      if (context_width / context_height) >= (page_width * splits / page_height)
        scale_rate = context_height / page_height
        context.scale(scale_rate, scale_rate)
        context.translate((context_width - scale_rate* splits * page_width) / scale_rate / splits, 0)
      else
        scale_rate = context_width / page_width / splits
        context.scale(scale_rate, scale_rate)
        context.translate(0, (context_height- scale_rate* page_height) / scale_rate / splits)
      end

      splits.times do
        |index|
        render_page(context, @virtual_page + (@invert ? index : splits - index - 1))
        context.translate(page_width, 0)
      end
    end
  end

  def forward_pages(n = 2)
    if @virtual_page < (@page_map.size - n)
      @virtual_page += n
    end
  end

  def back_pages(n = 2)
    if @virtual_page > 0
      @virtual_page -= n
    end
  end

  def go_page(n)
    @virtual_page = n if 0 < n and n < @page_map.size
  end

  def insert_blank_page_to_left
    begin
      @page_map.insert(@virtual_page + 1 , nil)
    rescue
    end
  end

  def insert_blank_page_to_right
    begin
      @page_map.insert(@virtual_page, nil)
    rescue
    end
  end

  def default_save_filepath
    Pathname.new(ENV['HOME']) + '.yamr.saves'
  end

  def load(save_filepath = default_save_filepath)
    data = (YAML.load_file(save_filepath) rescue {})[@pdf_filename.cleanpath.expand_path.to_s]
    return false unless data
    %W[invert splits virtual_page].each do
      |name|
      current = self.instance_variable_get("@#{name}")
      self.instance_variable_set("@#{name}", data[name.intern] || current)
    end
  end

  def save(save_filepath = default_save_filepath)
    data = (YAML.load_file(save_filepath) rescue {})
    key = @pdf_filename.cleanpath.expand_path.to_s
    data[key] = {
      :invert => @invert,
      :splits => splits,
      :virtual_page => @virtual_page
    }
    File.open(save_filepath, 'w') {|file| file.write(YAML.dump(data)) }
  end
end

if ARGV.size < 1
  puts "Usage: #{$0} file"
  exit 1
end

count = nil

filepath = Pathname.new(ARGV[0])
document = PDFDocument.new(filepath)
document.load

window = Gtk::Window.new

drawing_area = Gtk::DrawingArea.new
drawing_area.signal_connect('expose-event') do |widget, event|
  context = widget.window.create_cairo_context
  x, y, w, h = widget.allocation.to_a

  #背景の塗り潰し
  context.set_source_rgb(1, 1, 1)
  context.rectangle(0, 0, w, h)
  context.fill

  document.draw(context, w, h)
  true
end

window.signal_connect('key-press-event') do |widget, event|
  c = event.keyval.chr rescue nil

  if '0123456789'.scan(/\d/).include?(c)
    count = 0 unless count
    count *= 10
    count += c.to_i
    next true
  end

  single = count || 1
  double = count || document.splits

  case c
    when 'j'
      document.forward_pages(double)
    when 'k'
      document.back_pages(double)
    when 'b'
      document.insert_blank_page_to_right
      document.forward_pages(double)
    when 'H'
      document.insert_blank_page_to_left
    when 'L'
      document.insert_blank_page_to_right
    when 'g'
      document.go_page(single)
    when 'G'
      document.go_page(double)
    when 'v'
      document.invert()
    when 'r'
      document.load()
    when 'w'
      document.save()
    when 's'
      if count
        document.splits = count if (1 .. 10) === count
      else
        document.splits = document.splits > 1 ? 1 : 2
      end
    when 'q'
      document.save()
      Gtk.main_quit
  end

  count = nil

  drawing_area.signal_emit('expose-event', event)
  true
end

window.add(drawing_area)

page_width, page_height = document.page_size
window.set_default_size(page_width*2, page_height)
window.signal_connect("destroy") do
  document.save
  Gtk.main_quit
  false
end

window.show_all
Gtk.main
