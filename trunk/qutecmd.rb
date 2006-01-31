#!/usr/local/bin/ruby -w
# $Id$
#
# qutecmd -- Qute library for command-line utilities
#
# Copyright (c) 2004 Hewlett-Packard Development Company, L.P.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
#   * Redistributions of source code must retain the above copyright notice,
#     this list of conditions and the following disclaimer.
#   * Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
#   * Neither the name of the Hewlett-Packard Development Company, L.P.  nor
#     the names of its contributors may be used to endorse or promote products
#     derived from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

class String
  def lfit(width) self[0,width].ljust(width) end
  def rfit(width) self[0,width].rjust(width) end
end

class NilClass
  def lfit(width) '#' * width end
  def rfit(width) '#' * width end
end

module QuteCmd

begin
  require 'readline'
  Readline.completion_proc = proc {}
  #debug "loaded readline"
rescue LoadError
  #debug "failed to load readline"
end

# Determine the width of the terminal using ioctl(TIOCGWINSZ)
def QuteCmd::gettermsize
  return $termsize if defined? $termsize

  if $stdout.isatty
    # There's no POSIX::uname to figure out what the underlying system is, so
    # we have to call the external `uname`.  Also I think there's no ruby
    # equivalent to h2ph, so we hardcode the ioctl numbers.
    case `uname -s -m`
      when /^OSF1/ # Tru64
        $TIOCGWINSZ = 0x40000000 | ((8 & 0x1fff) << 16) | (116 << 8) | 104
      when /^Linux alpha/
        $TIOCGWINSZ = 0x40087468
      when /^Linux/ # hopefully x86
        $TIOCGWINSZ = 0x5413
      else
        $TIOCGWINSZ = nil # don't know this OS
    end

    # Allocate space for the return data prior to calling ioctl.
    str = [ 0, 0, 0, 0 ].pack('S4')
    if $TIOCGWINSZ && $stdout.ioctl($TIOCGWINSZ, str) >= 0 then
      rows, cols, xpixels, ypixels = str.unpack('S4')
      #debug "Calculated terminal size: #{rows}, #{cols}"
    end
  end

  # Use defaults if needed
  $termsize = [ (rows or 24), (cols or 79) ]
  return $termsize
end

# Mixin to String to wrap text that looks wrappable
module String
  def rewrap(cols = nil)
    rows, cols = QuteCmd::gettermsize if cols == 0 or cols == nil
    newtxt = ''
    self.split(/\n\s*\n/).each { |para|
      # First line in para must be longer than 80 columns and the second line
      # must start with non-whitespace.
      if para =~ /\A.{#{cols},}(\n\S|$)/
        para.gsub!(/(\S)\s+/, '\1 ')                       # unwrap
        para.gsub!(/(.{1,#{cols-5}})( +|\z)/, "\\1\n")     # rewrap
        newtxt += para + "\n"
      else
        newtxt += para + "\n\n"
      end
    }
    newtxt
  end

  def rewrap!(cols = nil)
    self.replace self.rewrap(cols)
  end
end

# This class acts like a writable file, but just saves the outgoing text to be
# later fetched by to_s.
class StringFile
  def initialize; @buf = []; end
  def write(str); @buf << str; end
  def to_s;       @buf.join; end
end

# Use this method to catch stdout and route it through a pager, add extra
# text, or send as email.
def QuteCmd::pkgoutput(cmdobj, pagerok = false)
  oldout = $stdout

  # Set up pager
  if cmdobj.settings.has_key? 'mailto'
    mailout = StringFile.new
    $stdout = mailout
  elsif pagerok and not cmdobj.settings.has_key? 'nopage'
    # Get the pager we want to use
    pagercmd = (cmdobj.settings['pager'] or ENV['QUTEPAGER'] or
      ENV['PAGER'] or 'more')
    begin
      # Use the pager as the default output
      pagerio = IO.popen("#{pagercmd} -", 'w')
      $stdout = pagerio
    rescue Errno::ENOENT
      # Error launching pager -- silently ignore
    end
  end

  # Generate the output we're packaging
  yield

  # Go back to normal stdout
  $stdout = oldout

  # If we're using mailout, send it where it belongs
  if mailout
    # Use template from file, or the inline default below
    if cmdobj.settings['template']
      msg = File.open(cmdobj.settings['template']) { |file| file.read }
    else
      msg = <<ENDTMPL
From: \#{user}
To: \#{mailto}
Subject: qute report

qute report \#{date}

\#{report}
This report was generated by the following command:
\#{command}

For more information on qute, see: http://qute.berlios.de/
ENDTMPL
    end

    # Collect the values available for the template, and apply them
    uservars = proc {
      user      = ENV['USER']
      mailto    = cmdobj.settings['mailto']
      date      = Date.today.to_s
      report    = mailout.to_s
      command   = cmdobj.to_s
      binding()
    }.call
    outstr = eval([ '%Q{', msg, '}' ].join, uservars)

    # Actually mail this if we have a mailto address
    if cmdobj.settings['mailto']
      sendmail = IO.popen("/usr/lib/sendmail #{cmdobj.settings['mailto']}", 'w')
      sendmail.write(outstr)
      sendmail.close
    else
      print outstr
    end
  end

  # Wait for pager to close
  pagerio.close if pagerio
end

# Save form data to a file
def QuteCmd::saveform(formid, form)
  # Pick a directory to use
  dirlist = []
  if ENV['HOME']
    begin
      Dir.mkdir(ENV['HOME'] + '/.qute')
    rescue
      # Ignore errors on this one.  We'll do the right thing below.
    end
    dirlist << ENV['HOME'] + '/.qute/old'
  end
  dirlist << '/tmp/qute'
  dirlist << '/tmp'
  dirlist << '/'

  # Make sure the directory exists
  begin
    dir = dirlist.shift
    Dir.mkdir(dir)
  rescue Errno::EEXIST
    # This is good, the directory exists.  Continue...
  rescue Exception
    retry if dirlist.length > 0
    puts "Failed to save form data"
    raise
  end

  # Write it out, and tell the user
  filename = "#{dir}/#{formid}-#{$$}.txt"
  File.open(filename, 'w') { |file| file.puts form.querystring }
  puts "Saved form data to #{filename}"
end

class NonAmbiguousHash < Hash
  def [](key)
    begin
      realkey = Qute.getnonambiguous(key, self.keys)
    rescue Qute::MatchNone
      return nil
    end
    super(realkey)
  end
end

def Qute::getline(prompt)
  if defined? Readline
    # We have the Readline module.  Use it.
    return Readline.readline(prompt, true)
  else
    # No readline module -- use standard stuff.
    $stdout.print prompt
    return $stdin.gets
  end
end

class FormFiller
end

class FormPrompter < FormFiller
  # XXX: try to make completion list ordered (not alphabetical)
  def FormPrompter.fillfields(fieldlist)
    if defined? Readline
      Readline.completion_case_fold = true  #XXX: shouldn't trample here
      oldproc = Readline.completion_proc
    end
    begin
      fieldlist.each do |field|
        next if not field or field.hidden

        # set the readline completion function for this field
        # XXX: seems to have trouble when choices contain spaces
        if defined? Readline
          Readline.completion_proc = proc { |str|
            field.choices.select { |choice|
              choice[0...str.length].downcase == str.downcase
            }
          }
        end

        # prompt the user and verify what is entered
        [0].each do
          default = (field.value and field.choices[field.value] or field.value)
          textval = Qute::getline('%s [%s]: ' % [field.title, default]).strip

          # If user entered something, adjust the field's value to match
          if textval != default and textval != '' then

            # fields with multiple choice must map from title back to value
            # XXX: allow caller to add its own short names to these choices
            # XXX: should we allow the user to enter value instead of a title?
            if field.choices.length > 0 then
              begin
                choice = Qute.getnonambiguous(textval, field.choices)
                if choice != textval
                  # the text entered by the user was incomplete, but we found
                  # a non-ambiguous match.  display what we chose.
                  puts choice
                end
                textval = field.choices.invert[choice]
              rescue MatchError
                # XXX: should caller handle this condition flexibly?
                puts "\nBad entry, try again."
                if field.choices.length < 20 then
                  puts "Choose one of:\n  %s" % [field.choices.join("\n  ")]
                end
                redo
              end
            end

            # apply value to field
            field.value = textval
          end
        end
      end

    rescue Exception
      # Get off of the prompt line
      puts
      raise
    ensure
      Readline.completion_proc = oldproc if oldproc
    end
  end
end

class FormTextEditor < FormFiller
  def FormTextEditor.writefile(file, fieldlist)
    # put header on text file
    file.puts "## To fill in this form, add or change the content in-between"
    file.puts "## pairs of dashed lines.  Changes to any other portion of"
    file.puts "## this file will be ignored."

    # generate some text for each form field
    fieldlist.each do |field|
      next if field.hidden or field.password

      # write out the prompt
      file << "\n\n"
      file << field.prompt if field.prompt
      file << "o %s:\n" % field.title

      # write out the body prefix
      sep = ('-      '*11)[0..-field.name.length-2] + (" - %s\n" % field.name)
      file << sep

      # write out the body
      case field.choices.length
      when 0..1       # this is a simple text entry field
        file << field.value << "\n"
      when 2..25      # multiple-choices to be represented with checkboxes
        field.choices.each do |choice|
          checked = field.choices[field.value] == choice
          file << (checked ? '[x] ' : '[ ] ') << choice << "\n"
        end
      else            # multi-choice, but too many to list: use choice title
        file << field.choices[field.value] << "\n"
      end

      # write out the body suffix
      file << sep
    end
  end

  # XXX: collect form parsing errors and report all to the user at the end
  # XXX: make all the parsing more robust and catch more user errors
  def FormTextEditor.readfile(file, fieldlist)
    sepre = %r{^(?:- {6}){4,}-? * - (.*)$}
    while not file.eof? do
      # read in text looking for a field body
      file.each_line { |line| line =~ sepre and break }
      fieldname = $1

      # read in body looking for suffix
      body = ''
      file.each_line do |line|
        break if line =~ sepre
        body << line
      end
      $1 == fieldname or raise "Broken field body %s/%s" % [$1, fieldname]
      body.chop!

      # process body
      field = fieldlist.detect { |field| field.name == fieldname }
      if field.choices.length > 0 then
        # multiple-choice -- we need to figure out if there are checkboxes
        bodylines = body.split("\n")
        if bodylines.length > 1 then  # XXX: make this check more complete
          # multiple-choice with checkboxes
          bodylines.each do |line|
            if line[0..3].downcase == '[x] ' then
              field.value = field.choices.invert[line[4..-1]] or raise "Bad form value"
              break
            end
          end
        else
          # multiple-choice with body as choice title
          field.value = field.choices.invert[body] or raise "Bad form value: (%s) %s" % [body, field.choices]
        end
      else
        # simple text-entry field
        field.value = body
      end
    end
  end

  def FormTextEditor.fillfields(fieldlist)
    # create temp file with form text
    file = Tempfile.new('qute')
    FormTextEditor.writefile(file, fieldlist)
    file.close

    # launch editor to modify temp file
    `#{ENV['EDITOR'] || "vi"} #{file.path}`

    # read in form text and apply to form
    file.open
    FormTextEditor.readfile(file, fieldlist)
    file.close(true)
  end
end

class FormCommandLine < FormFiller
  def FormCommandLine.fillfields(fieldlist, pairs)
    pairs.each do |pair|
      key, val = pair.split('=')
      next unless val
      key.downcase!
      matchfields = fieldlist.select { |field|
        field.name[0,key.length].downcase  == key or
        field.title[0,key.length].downcase == key
      }
      matchfields[0].value = val
    end
  end
end

# This class makes it easy to generate ANSI escape sequences for changing the
# terminal foreground color, background color, and attribute.  It provides
# constants for each of the foreground colors and attributes, and the class
# method 'block' so that you don't have to use the full class identifier for
# each constant.
class AnsiColor
  attr_reader :pairs

  def initialize(*p); @pairs = p;                       end
  def BG;             AnsiColor.new('4'+pairs[0][1,1]); end #Background version
  def +(x);           AnsiColor.new(pairs + x.pairs);   end #Combine AnsiColors
  def to_s;           "\e[" + pairs.join(';') + 'm';    end #Generate ANSI

  # Allow a block of code to refer to AnsiColor's class constants
  def AnsiColor.block(usecolor = true, &block)
    if usecolor
      instance_eval(&block)
    else
      AnsiColorNull.block(&block)
    end
  end

  # This allows the colors to be named as lower-case method calls, since the
  # upper-cased constants seem to have stopped working
  def AnsiColor.method_missing(name)
    color = name.to_s
    color = color[0..0].upcase + color[1..-1]
    eval color
  end

  # Color and attribute constants
  Black     = AnsiColor.new('30');  Normal    = AnsiColor.new('00')
  Red       = AnsiColor.new('31');  Bold      = AnsiColor.new('01')
  Green     = AnsiColor.new('32');
  Yellow    = AnsiColor.new('33');
  Blue      = AnsiColor.new('34');  Under     = AnsiColor.new('04')
  Magenta   = AnsiColor.new('35');
  Cyan      = AnsiColor.new('36');  Hidden    = AnsiColor.new('06')
  White     = AnsiColor.new('37');  Reverse   = AnsiColor.new('07')
end
class AnsiColorNull < AnsiColor
  def AnsiColorNull.block(&block); instance_eval(&block); end
  def AnsiColorNull.method_missing(name); ''; end
  Black   = ''; Red     = ''; Green   = ''; Yellow  = ''; Blue    = '';
  Magenta = ''; Cyan    = ''; White   = ''; Normal  = ''; Bold    = '';
  Under   = ''; Hidden  = ''; Reverse = '';
end

class OutputColumn
  attr_accessor :name, :align, :width, :shortname, :valalias

  def initialize(name)
    @name = name
    @shortname = name
    @width = 0
    @valalias = {}
  end

  def fitstr(str)
    # Using to_s converts nils to blanks, instead of to #'s
    str = ( @valalias[ str.to_s ] or str )
    if defined? @align and @align == 'right'
      str.to_s.rfit(@width)
    else
      str.to_s.lfit(@width)
    end
  end
end

# This class stores a list of column names we want to use, and provides
# methods to get strings for output grid headers and records with those
# columns.
class OutputGrid
  attr_accessor :colset
  attr_reader   :collist
  attr_writer   :width

  def initialize(colset = nil, width = nil)
    @colset = colset
    @width = width

    @collist = []
  end

  def addcol(colname)
    # Try deleting this first.  If it doesn't work, don't worry.
    begin
      self.delcol(colname)
    rescue Qute::MatchError
    end

    # Now try adding it.
    if colname =~ /^(.*)([-+])(\d+)$/
      # We were given aligment and width details.  Apply them to either and
      # existing column (with it's full name), or a new generic column.
      col = (@colset[$1] or OutputColumn.new($1))
      col.align = $2 == '-' ? 'left' : 'right'
      col.width = $3.to_i
    elsif @colset and @colset[colname]
      # No details were given, and we've got good defaults -- use them.
      col = @colset[colname]
    else
      # No defaults for output column "col", just use a generic column with
      # the name given by the user.
      col = OutputColumn.new(colname)
    end
    @collist << col
  end

  def delcol(colname)
    namelist = @collist.map { |col| col.name }
    fullcolname = Qute.getnonambiguous(colname, namelist)
    @collist.delete_if { |col| col.name == fullcolname }
  end

  def freeze
    # Skip all this if we're already frozen
    return if frozen?

    # Now calculate column widths before actually freezing.
    # First, calculate our target width
    rows, width = QuteCmd::gettermsize if not @width or @width == 0
    tgtwidth = width - @collist.length + 1

    # Pick out the columns with a width of zero; also reduce tgtwidth
    zcols = @collist.select { |col|
      tgtwidth -= col.width
      col.width == 0
    }

    zcols.each_with_index do |col, i|
      col.width = (tgtwidth / (zcols.length - i)).round
      col.width = 1 if col.width < 1
      tgtwidth -= col.width
    end

    # Actually freeze
    super
  end

  def rowstr
    freeze

    @collist.map { |col|
      colstr = yield(col)
      col.fitstr(colstr)
    }.join(' ')
  end
end

# Each SynopsisGrid can have multiple output rows that are actually each
# handled by a separate OutputGrid.  The field defaults for width, alignment,
# etc. come from the colset.
class SynopsisGrid
  attr_reader :grids, :colset
  attr_accessor :colorok

  def initialize(cmdobj)
    @cmdobj = cmdobj

    @colorok = false
    @colset = nil

    # Custom list of grids, one for each row.
    @grids = []
  end

  # Decide if we're going to color or not.
  def usecolor
    return @usecolor if defined? @usecolor
    if @cmdobj.settings.has_key? 'nocolor'   then @usecolor = false
    elsif @cmdobj.settings.has_key? 'mailto' then @usecolor = false
    elsif not @colorok                      then @usecolor = false
    else                                         @usecolor = $stdout.tty?
    end
    #debug "Use color? #{@usecolor}"
    return @usecolor
  end

  # Return a pair of ANSI color strings for this grid row -- the first
  # for the start of the record, the second to set the color back to normal
  def getcolors(gridrow)
    AnsiColor.block(usecolor) do
      return normal, normal
    end
  end

  # Each SynopsisGrid can have multiple output rows that are actually each
  # handled by a separate OutputGrid.  This adds a new OutputGrid row with
  # columns of the given names.
  def addrow(collist)
    grid = OutputGrid.new(@colset)
    collist.each do |colname|
      grid.addcol(colname)
    end
    @grids << grid
  end

  # Print out the column names for the first row of detail
  def showheader( grid = nil, dashes = true )
    grid ||= @grids[0]
    AnsiColor.block(usecolor) do
      puts [ bold, (grid.rowstr { |col| col.name }), normal ].join
      puts [ bold, (grid.rowstr { |col| '-' * 99 }), normal ].join if dashes
    end
  end

  # Print out either all the detail rows for this record, or the 'nopublish'
  # detail.
  def showrecord(record, &pregrid)
    color, normal = getcolors(record)
    @grids.each do |grid|
      pregrid and pregrid.call( grid )
      rowstr = grid.rowstr { |col|
        value = ( record[col.shortname] || '' )
        value = value.gsub(/\s+/, ' ').strip
      }
      puts [color, rowstr, normal].join
    end
    puts if @grids.length > 1
    return true
  end
end

ArgNone = 0
ArgRequired = 1
ArgOptional = 2

class OptsSynopsis
  def validopts(cmdobj)
    # Command-line options for customizing the output grid
    return [
      [ 'addcolumn', ArgRequired ],
      [ 'delcolumn', ArgRequired ],
    ]
  end

  def applyopts(cmdobj)
    cmdobj.each(self) do |opt, arg, flags|
      case opt
      when 'addcolumn'
        cmdobj.syngrid.grids[0].addcol(arg)
      when 'delcolumn'
        cmdobj.syngrid.grids[0].delcol(arg)
      end
    end
  end
end

class OptsSettings
  def validopts(cmdobj)
    # These are the settings options that will be available through
    # cmdobj.settings
    return [
      [ 'nowrap',       ArgNone ],
      [ 'width',        ArgRequired ],
      [ 'nopage',       ArgNone ],
      [ 'debug',        ArgNone ],
      [ 'template',     ArgRequired ],
      [ 'mailto',       ArgOptional ],
      [ 'nocolor',      ArgNone ],
      [ 'pager',        ArgRequired ],
      [ 'loadform',     ArgRequired ],
    ]
  end

  def applyopts(cmdobj)
    cmdobj.each(self) do |opt, arg, flags|
      if opt == 'debug'
        # Debug is even more global than the current command.
        $QUTEDEBUG = true
      else
        # All these other settings are properly associated with a specific
        # run of a command, so don't store them is a totally global place.
        cmdobj.settings[opt] = arg
      end
    end
  end
end

# This class defines the command-line interface for general query form fields,
# including the Not, Match (aka exact), and Case checkboxes, as well as simple
# aliases.
class OptsFormFields
  attr_accessor :fieldalias
  private :fieldalias

  def initialize(queryform)
    @fieldalias = {}
    @queryform = queryform
  end

  def validopts(cmdobj)
    opts = @queryform.map { |field| 
      if field.choices.length > 0 and not field.multiple
        [ field.name, ArgRequired ]
      else
        [ field.name, ArgOptional ]
      end
    }

    # Add aliases for several of the form fields
    self.fieldalias.each { |ali,name|
      opts.push [ ali, opts.assoc(name)[1] ]
    }

    # Return the list of options OptsFormFields knows how to handle.
    return opts
  end

  def applyopts(cmdobj)
    cmdobj.each(self) do |opt, arg, flags|
      # Change opt to actual field name if it is an alias
      opt = self.fieldalias[opt] if self.fieldalias[opt]

      # Adjust argument if choices are given for this field
      if @queryform[opt].choices.length > 0 then
        if @queryform[opt].multiple then
          # Ruby doesn't support look-behind so this is the best we can
          # do at the moment
          args = arg.gsub(/([^\\]|^)\+/, '\1'+"\n")
          args.gsub!(/\\(.)/, '\1')
          args = args.split "\n"
          # If the first character was '+' then we will append to
          # existing set below
          args.shift if arg[0,1] == '+'
        else
          # Not a multiple select... but normalize to array to make
          # the code uniform
          args = [ arg ]
        end

        fullchoices = @queryform[opt].choices
        args.map! { |a|
          a = Qute.getnonambiguous(a, fullchoices)
          a = fullchoices.invert[a]
        }

        if @queryform[opt].multiple then
          # Include original values if arg starts with '+'
          args = (@queryform[opt].value + args).sort.uniq if arg[0,1] == '+'
          @queryform[opt].value = args
        else
          @queryform[opt].value = args[0]
        end
      else
        # Apply the value to the form field
        @queryform[opt].value = arg
      end
    end
  end
end

# This class is the main driver and interface for the above Opts classes.  An
# instance of this class represents one "qute command" and encapsulates all
# the state necessary for executing that command.
class QuteCmdObj
  # usually the first argument, such as "read", "query", "update", etc.
  attr_reader :command
  
  # hash of option/argument pairs from the cmdline, see OptsSettings
  attr_reader :settings

  # default arguments for when none are given, if wanted should be set by the
  # instance before calling parseargs!
  attr_accessor :defaultargs
  
  # synopsis grid associated with this command, if wanted should be set by the
  # instance before calling parseargs!
  attr_accessor :syngrid

  def initialize(cmdlist, argv = ARGV)
    @syngrid = nil
    @defaultargs = []
    @actualopts = []
    @settings = {}
    @optobjlist = []
    @command = 'read'  # default command

    # First, get the command
    if argv.length < 1 then
      raise "#{$ZERO} requires arguments"
    elsif argv[0].to_i.to_s != argv[0]
      # When the command is not a number, it's a real command.
      @command = argv.shift
    end

    # What's left in argv are the command arguments
    @args = argv

    # Send the command, passing ourselves as the parameter
    @command = Qute.getnonambiguous(
      @command, cmdlist.class.instance_methods(false) )
    cmdlist.send(@command, self)
  end

  def to_s
    "#{$ZERO} #{@command} #{@args.join(' ')}"
  end

  # Option string to use when only a number is specified on the
  # command line.  Usually something like 'id', 'number', etc.
  def numberOptStr
    nil
  end

  def getflags( optstr, opthash )
    return {}, Qute.getnonambiguous(optstr, opthash.keys)
  end

  def parseargs!
    # Generate an instance of each Opts class that is useful for this command
    @optobjlist << QuteCmd::OptsSettings.new
    if @syngrid
      # If we're going to use a SynopsisGrid, let the user customize it
      @optobjlist << QuteCmd::OptsSynopsis.new
    end

    # Use defaultargs if none were given
    @args.length == 0 and @args = @defaultargs

    # Generate a list of all possible options from each of the Opts objects
    opthash = {}
    @optobjlist.each do |optobj|
      optobj.validopts(self).each do |optstr, argreq|
        opthash[optstr] = [ optobj, argreq ]
      end
    end

    # Walk through all the @args, process, and store the results
    i = -1
    while i < @args.length-1
      # advance to next argument
      i += 1
      optstr = @args[i]

      # check for raw number
      param = nil
      if optstr.to_i.to_s == optstr
        # plain number implies some kind of filter opt
        param = optstr
        optstr = self.numberOptStr
      end

      # delete leading punctuation from command
      optstr = optstr.sub %r(^[/-]+), ''

      # allow modifier flags on the front of filter commands
      flags, optstr = self.getflags( optstr, opthash )

      # get the optobj that registered this option
      optobj, argreq = opthash[optstr]

      # if this option takes a parameter, consume it
      param ||= case argreq
        when ArgNone;     param = nil
        when ArgRequired; @args[i+=1]
        when ArgOptional; @args[i+1] =~ %r(^[/-]) ? nil : @args[i+=1]
          # XXX What is this else really catching?  It appears that ArgOptional is
          # implemented above...
        else
          p optstr, optobj, argreq
          raise %Q(Optional parameters are not yet implemented)
        end

      # store what we know about this option and it's parameter
      #p [ optobj, optstr, param, flags ]
      @actualopts << [ optobj, optstr, param, flags ]
    end

    # call all Opts objects to process their options
    @optobjlist.each do |optobj|
      optobj.applyopts(self)
    end

    # Print version if in debugging mode
    #debug $VERSIONMSG
  end

  # Iterate through the command-line options
  def each(optobj)
    @actualopts.each do |opt|
      if opt[0] == optobj
        yield opt[1..3]
      end
    end
  end
end


end # module QuteCmd
