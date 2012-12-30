#!/usr/bin/env ruby
# vim: set fileencoding=utf-8 :

require 'gtk2'
require 'poppler'
require 'pathname'
require 'yaml'

class PDFDocument
  attr_accessor :splits
  attr_reader :pdf_filepath

  def initialize(pdf_filepath, blank_page_filename=nil)
    if blank_page_filename
    end

    @pdf_filepath = pdf_filepath.cleanpath.expand_path
    @document = Poppler::Document.new(pdf_filepath.to_s)

    @total_page = @document.size

    @virtual_page = -1

    @page_map = []
    (0..@total_page-1).each { |i|
      @page_map[i] = i
    }

    @count = 1
    @invert = false
    @splits = 2

  end

  def invert
    @invert = !@invert
  end

  def current_page_number
    @virtual_page + 2
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
        page = @virtual_page + (@invert ? index : splits - index)
        render_page(context, page)
        context.translate(page_width, 0)
      end
    end
  end

  def forward_pages(n = 2)
    if current_page_number < (@total_page - n)
      @virtual_page += n
      true
    else
      false
    end
  end

  def back_pages(n = 2)
    if current_page_number > n
      @virtual_page -= n
      true
    else
      false
    end
  end

  def go_page(n)
    n = @total_page + n + 1 if n < 0
    n -= 2
    @virtual_page = n if -1 <= n and n < @page_map.size
  end

  def insert_blank_page_to_left
    begin
      @total_page += 1
      @page_map.insert(@virtual_page + 1 , nil)
    rescue
    end
  end

  def insert_blank_page_to_right
    begin
      @total_page += 1
      @page_map.insert(@virtual_page, nil)
    rescue
    end
  end

  def default_save_filepath
    Pathname.new(ENV['HOME']) + '.yamr.saves'
  end

  def load(save_filepath = default_save_filepath)
    data = (YAML.load_file(save_filepath) rescue {})[@pdf_filepath.cleanpath.expand_path.to_s]
    return false unless data
    %W[invert splits virtual_page].each do
      |name|
      current = self.instance_variable_get("@#{name}")
      self.instance_variable_set("@#{name}", data[name.intern] || current)
    end
  end

  def save(save_filepath = default_save_filepath)
    data = (YAML.load_file(save_filepath) rescue {})
    key = @pdf_filepath.cleanpath.expand_path.to_s
    data[key] = {
      :invert => @invert,
      :splits => splits,
      :virtual_page => @virtual_page
    }
    File.open(save_filepath, 'w') {|file| file.write(YAML.dump(data)) }
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

    "#{pdf_filepath.basename.sub_ext('')} [#{current_page}/#{@total_page}]"
  end
end

class YAMR
  def self.next_file(filepath)
    es, i = self.get_dir_info(filepath)
    return nil unless i
    i += 1
    i < es.size ? es[i] : es.first
  end

  def self.previous_file(filepath)
    es, i = self.get_dir_info(filepath)
    return nil unless i
    i -= 1
    i >= 0 ? es[i] : es.last
  end

  def self.get_dir_info(filepath)
    dir = filepath.dirname
    es = dir.entries.sort.map {|it| (dir + it).cleanpath.expand_path }
    i = es.index(filepath)
    return es, i
  end
end


if ARGV.size < 1
  puts "Usage: #{$0} file"
  exit 1
end

count = nil
save_counter = 0

filepath = Pathname.new(ARGV[0])
document = PDFDocument.new(filepath)
document.load

window = Gtk::Window.new

window.title = document.caption

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
  double = single * document.splits

  case c
    when 'j'
      unless document.forward_pages(double)
        next_file = YAMR.next_file(document.pdf_filepath)
        document = PDFDocument.new(next_file) if next_file
      end
    when 'k'
      unless document.back_pages(double)
        previous_file = YAMR.previous_file(document.pdf_filepath)
        document = PDFDocument.new(previous_file) if previous_file
        document.go_page(-document.splits)
      end
    when 'J'
      document.forward_pages(single)
    when 'K'
      document.back_pages(single)
    when 'b'
      document.insert_blank_page_to_right
      document.forward_pages(double)
    when 'H'
      document.insert_blank_page_to_left
    when 'L'
      document.insert_blank_page_to_right
    when 'g'
      document.go_page(count ? (count - 1) / document.splits * document.splits + 1 : 1)
    when 'G'
      document.go_page(count || -document.splits)
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
    else
      next
  end

  if save_counter > 10
    save_counter = 0
    document.save()
  else
    save_counter += 1
  end

  count = nil
  window.title = document.caption

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
