#!/usr/local/bin/ruby -w
# $Id: qute.rb,v 1.43 2004/09/16 16:19:38 agriffis Exp $
#
# qute -- Quick Utility for Tracking Errors
# 
# Copyright (c) 2002 - 2004 Hewlett-Packard Development Company, L.P.
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

require 'net/http'
require 'cgi'
require 'uri'
require 'tempfile'

begin
  require 'readline'
  Readline.completion_proc = proc {}
  #debug "loaded readline"
rescue LoadError
  #debug "failed to load readline"
end

module Qute
CVSREV = %Q$Revision: 1.43 $.gsub(/(^.*: | $)/, '')

# Parse SGML-like text.  Should be subclassed, with children overriding
# methods of the form start_foo, end_foo, and foo_tag, which will be called
# with a SGMLParser::Token object as a paremeter when any of these tokens are
# encountered in the input stream.  The input stream is fed to SGMLParser
# objects via the << method.
class SGMLParser
  OPTSRE = %r{
    ([^\s>=]+) (?:=\s*"([^"]*)" | =\s*'([^']*)' | =\s*([^\s>]+))?
  }x

  SGMLRE = %r{
    (\A[^&<]+) |                                # text
   # this next line breaks ruby on Tru64:
   #(\A<[^<>=]*(?=<)) |                         # broken text
    (\A&\#?\w*(?=\W);?) |                       # entity
    (\A<!--(?:.|\s)*?-->) |                     # comment
    (\A</[-:\w]+>) |                            # close tag
    (\A<!\w+ (?:\s*(?:[^\s>]*|"[^"]*"))*\s*>) | # declaration tag
    (\A                                         # open tag
      <([?]?) \s* 
      ([-:\w]+ )
      (?:\s+ #{OPTSRE.source} )*
      \s* ([?/]?) \s*>
    )
  }x

  # This object is a string, but also can contain a list of link urls
  class CaptureObj < String
    attr_reader :links

    def initialize
      @links = []
    end
  end

  # This object provides an interface to a single token's-worth of SGML-stream
  # text.  A token is a start or end tag, an SGML comment, a piece of plain
  # text, or an entity.
  class Token
    attr_reader :object, :tag

    def initialize(matchdata)
      @matchdata = matchdata

      @s = nil          # cached value of to_s
      @opts = nil       # cached value of opts

      # calculate object and tag
      i = 0
      @object, @tag = if @matchdata[i+=1] then ['text', '']
       #elsif @matchdata[i+=1] then ['text', '']
        elsif @matchdata[i+=1] then ['entity', '']
        elsif @matchdata[i+=1] then ['comment', '']
        elsif @matchdata[i+=1] then ['end',%r{\A</(.*)>\Z}.match(to_s)[1].downcase]
        elsif @matchdata[i+=1] then ['other', '']
        elsif @matchdata[i+=1] then ['start', @matchdata[i+2].downcase]
        else raise "Parse failure:\n(%s)" % matchdata
      end
    end

    def to_s(pre = false)
      return @s if @s

      # if pre is false, collapse whitespace and unescape entities
      @s = if pre then
        @matchdata.to_s
      else
        CGI.unescapeHTML(@matchdata.to_s.tr_s(" \t\n", ' ').strip)
      end
      @s
    end

    def opts
      return @opts if @opts

      @opts = {}
      to_s.gsub OPTSRE do
        optname = $1.downcase
        next if optname == @tag
        noesc = ($2 or $3 or $4 or '')
        esc = CGI.unescapeHTML(noesc)
        puts "#{noesc} -> #{esc}" if noesc != esc
        @opts[optname] = esc
      end
      @opts
    end

    def [](opt)
      opts[opt]
    end
  end

  class TextToken < Token
    def initialize(text)
      @s = text
      @object, @tag = 'text', ''
    end
  end

  def initialize
    @parsebuf = ''      # buffer of input text yet to be parsed
    @pre = false        # does captured text retain it's whitespace formatting?
    @capture = true     # are we currently capturing text tokens?
    @capobj = CaptureObj.new   # text and data captured so far
  end

  # start capturing text tokens into our capture buffer
  def startcapture(pre = false)
    @pre = pre
    @capture = true
    @capobj = CaptureObj.new
  end

  # stop capturing text and return the current contents of our capture buffer
  def endcapture
    @capture = false
    tmp, @capobj = @capobj, CaptureObj.new
    return tmp
  end

  # catch calls to start_foo, end_foo, and foo_tag methods that are made from
  # << and not defined by any sub-class
  def method_missing(mid, *args)
    # Leaving out the body of this function can obscure bugs, but leaving it
    # in impacts performance.  I'll comment this out for now, but it should be
    # uncommented any time "weird" behaviour is seen, so that a useful error
    # message may be obtained.

    #return if args.length == 1 and args[0].is_a? Token
    #super
  end

  def <<(addbuf)
    # add new data to parsebuf
    @parsebuf << addbuf

    # parse as much at the beginning as parsebuf as we can
    loop do
      # peel one token off the beginning of the SGML buffer and process it
      token = nil
      @parsebuf.sub! SGMLRE do
        token = Token.new($~)
        ''
      end or break

      # process xmp tags specially
      if token.object == 'start' and token.tag == 'xmp' then
        texttoken = nil
        @parsebuf.sub! %r{^(.*?)</xmp>}mi do
          texttoken = TextToken.new($1)
          ''
        end
        if not texttoken then
          # since we failed to find matching open and close xmp tags, push the
          # xmp-open tag back on the front of the parse buffer and go around
          # again.  XXX: this should be handled more cleanly
          @parsebuf = token.to_s + @parsebuf
          break
        end
        token = texttoken
      end

      # call general token handler, if it's defined
      # print token.object, token.to_s, "\n"
      do_token token

      # all tokens are then processed based on the type of object
      if token.object == 'start' or token.object == 'end' then
        # start and end tokens are processed by calling methods named
        # start_foo or end_foo, and foo_tag.  any of these that are not
        # defined by a subclass are caught and thrown away by method_missing
        self.send('%s_%s' % [token.object, token.tag], token)
        self.send('%s_tag' % [token.tag], token)

      end

      if @capture
        case token.object
        when 'text'
          # text tokens are thrown away unless we are capture is true, in which
          # case we append the text to our capture buffer
          #XXX: add support for entities
          @capobj << token.to_s(@pre)
        when 'start'
          case token.tag
          when 'a';     @capobj.links << token['href']  # also capture link urls
          when 'br';    @capobj << "\n"
          when 'p';     @capobj << "\n\n"
          end
        end
      end
    end
  end
end

class OrderedHash < Array
  def initialize
    super
    @hash = {}
  end

  def []=(key, val)
    delete key
    @hash[key] = val
    self << val
  end

  def [](key)
    (key.is_a? String) ? @hash[key] : super
  end

  def delete(key)
    super self[key]
    @hash.delete key
  end

  def invert
    @hash.invert
  end

  # XXX: should the val object be required to have a settable 'name' attribute
  # or some such, for mapping from value back to the list position?
  def keys
    inv = @hash.invert
    map do |val| inv[val] end
  end
end

class FormField
  attr_accessor :name, :value, :hidden, :password, :prompt
  attr_reader   :choices
  attr_writer   :title

  def initialize
    @name = nil                 # formal name of this form field
    @value = nil                # current value of this field
    @hidden = false             # should we hide the existance of this field?
    @password = false           # should we mask out the value of this field?
    @prompt = nil               # extra text describing this field
    @choices = OrderedHash.new  # list of choices if this is multiple-choice
    @title = nil                # informal descriptive name of this field
  end

  def title
    @title or @name
  end
end

class Form < OrderedHash
  attr_accessor :sourceurl, :targeturl, :cookie
  @@http = nil

  def initialize(targeturl = nil, prevobj = nil)
    super()
    if prevobj then
      @targeturl = prevobj.sourceurl.merge(targeturl)
      @sourceurl = prevobj.sourceurl
      @cookie = prevobj.cookie
    else
      @targeturl = targeturl ? URI::parse(targeturl) : nil
      @sourceurl = nil
      @cookie = nil
    end
  end

  # convert self into a URL-escaped string for posting
  def querystring
    map { |field|
      '%s=%s' % [CGI.escape(field.name), CGI.escape(field.value || '')]
    }.join('&')
  end

  # parse a URL-escaped string and load the resulting values
  def loadquery(query)
    query.split(/&/).each { |keyval|
      key, value = keyval.split(/=/, 2).map { |str| CGI.unescape(str) }

      # Compare values being loaded against those in the live form
      field = self[key]
      if not field and not has_key? key
        puts "Warning: Live form has no field #{key}... skipping"
        next
      end
      if field.choices.length > 0
        # This is a multiple-choice field.  Make sure the loaded value is in
        # the list of choices.
        if not field.choices[value]
          puts "Warning: Live form has no choice #{value} for field #{key}"
        end
      end

      # Skip loading hidden fields.  This means the user should be able to
      # have control over all the values we load.  I think this is always what
      # we want.
      next if field.hidden

      # Load the value into our field.
      field.value = value
    }
  end

  # post form data to CGI @action on server @host
  def post(parserclass = nil)
    @targeturl or raise "No target url -- cannot post"

    # if a parserclass was passed in, create an instance and set it up as the
    # http.post destination object
    if parserclass then
      dest = parserclass.new

      # the new object's sourceurl is our own targeturl
      # this is used for setting the next post's referer
      dest.sourceurl = targeturl
    end

    # connect to web host unless we already have a matching http object
    if not @@http or @@http.address != @targeturl.host then
      @@http = Net::HTTP.new(@targeturl.host)
    end

    # send the data
    headers = {
      'Content-Type' => 'application/x-www-form-urlencoded',
      'Cookie' => @cookie || '',
      'UserAgent' => 'qute',
      'Referer' => @sourceurl ? @sourceurl.to_s : @targeturl.to_s
    }
    path = @targeturl.path + (@targeturl.query ? '?' + @targeturl.query : '')
    #puts "Query:"
    #p path
    #p querystring
    #p headers
    if querystring == ''
        resp = @@http.get(path, headers, dest)
    else
        resp = @@http.post(path, querystring, headers, dest)
    end

    # 1.6.8 / 1.8.0 compatibility: 
    # 1.6.8 returns [resp,data] where 1.8.0 returns only resp
    if RUBY_VERSION < "1.8"
        resp = resp[0]
    end

    # return value depends on if a parserclass was passed in
    if parserclass then
      # set the data object generator's cookie
      dest.cookie = $1 if resp['set-cookie'] =~ /^([^;]*)/

      # return the data object created by the parser instance
      dest.verify
      return dest.dataobj
    else
      # return the raw response data from the web server
      return [resp, resp.body]
    end
  end
end

class FormList < Array
  attr_reader :sourceurl, :cookie

  def sourceurl=(url)
    @sourceurl = url
    self.each do |form|
      form.sourceurl = url
    end
  end

  def cookie=(c)
    @cookie = c
    self.each do |form|
      form.cookie = c
    end
  end
end

class TableRow < DelegateClass(Array)
#class TableRow < Array
  attr_accessor :rowtype
  attr_reader :table
  attr_reader :rownum

  def initialize(myrowtype = nil)
    # Use delegate instead of direct superclass to work around a bug in ruby
    # 1.6.8 which caused instance vars to incorrectly appear un-initialized.
    super([])
    #@test = 5
    #raise "bug" unless @test
    #super()

    @rowtype = myrowtype        # header or data row?
    @table = nil        # table to which this row belongs
    @rownum = nil       # index in @table where I appear
  end

  # When we are told what table we belong to, we can also discover and store
  # our index (rownum) in that table.
  def table=(table)
    @table and raise 'table=%#x, this row already has table=%#x.' % [table.id, @table.id]
    @table = table
    @rownum = @table.rindex(self)
  end

  # Create a TableRecord object using headers starting with this row
  def eachrecord(rows = 1)
    # build a record with all consecutive headers starting with self
    record = TableRecord.new(rows)
    table[@rownum..-1].each do |row|
      break if row.rowtype != 'header'
      record.addheader row
    end

    # now use the TableRecord's own iterator
    record.each do
      yield record
    end
  end
end

class TableRecord
  attr_reader :headers

  def initialize(reclen = 1, headers = [])
    @reclen = reclen    # length of this sliding window in rows
    @headers = headers  # list of headers to use as key patterns
    @advanceoffset = 1  # current offset from each header into the table
    @patterncache = {}  # cache of key patterns
    @table = nil        # table over which this sliding window iterates
    @aliases = {}       # list of aliases for field names
  end

  def table
    @table or @table = @headers[0].table
  end

  def addheader(*headers)
    @headers.push(*headers)
  end

  def alias(new, old)
    @aliases[new] = old
  end

  def unalias(name)
    @aliases.delete name
  end

  def advance(inc = @reclen)
    # advance the offset
    @advanceoffset += inc
  end

  # This is a little unusual, in that "each" doesn't mean iterate through this
  # object's contents, but instead advance this sliding window into a table,
  # until we reach the end of the table.
  def each
    loop do
      # stop looping if the first data row is table edge or header row
      row = table[headers[0].rownum + @advanceoffset + headers.length - 1]
      return if not row or row.rowtype != 'data'

      # yield ourselves, at the current position
      yield self

      # advance ourselves to the next position
      self.advance
    end
  end

  def indexes(*patterns)
    patterns.map { |pattern| self[pattern] }
  end

  def [](pattern, recordcol = nil)
    # apply aliases
    loop do
      break unless @aliases.has_key? pattern
      pattern = @aliases[pattern]
    end

    if recordcol then
      # if two parameters were passed in, us them as the recordrow and recordcol
      rowoffset = @headers[0].rownum + pattern
    elsif pattern.is_a? String and pattern =~ /^(\d*),(\d*)$/ then
      # two parameters passed as a string
      rowoffset = @headers[0].rownum + $1.to_i
      recordcol = $2.to_i
    else
      # if pattern is a string, convert it to a regexp
      if not pattern.respond_to? :source
        pattern = Regexp.new(pattern)
      end
      rowoffset, recordcol = @patterncache[pattern.source]
    end

    # find a header with a cell that matches the pattern
    if not recordcol then
      @headers.each do |header|
        header.each do |cell|
          if cell =~ pattern then
            # found a matching header cell -- calculate the data cell coords
            rowoffset = header.rownum
            recordcol = header.index(cell)
            # cache the coords
            @patterncache[pattern.source] = [rowoffset,recordcol]
            break
          end
        end
        break if recordcol
      end
    end

    # found a match -- get the data cell and return it
    if rowoffset and recordcol and table[rowoffset + @advanceoffset] then
      return table[rowoffset + @advanceoffset][recordcol]
    end

    # no match found -- return nil
    return nil
  end
end

class Table < Array
  attr_accessor :sourceurl, :cookie

  def initialize
    super
    @allheaders = nil   # cache of all header rows in this table
    @record = nil       # TableRecord indexing all headers in this table
  end

  def push(row)
    super
    row.table = self
  end

  def allheaders
    @allheaders or @allheaders = reject { |row| row.rowtype != 'header' }
  end

  # This TableRecord is not meant to be advanced at all.  It is instead to be
  # used to get the values of cells immediately beneath header cells in the
  # table.
  def record
    @record or @record = TableRecord.new(1, allheaders)
  end

  #XXX: could this use or be used by TableRecord#[]?
  def eachheader(*patternlist)
    allheaders.each do |header|
      catch :skipheader do
        patternlist.each do |pattern|
          throw :skipheader unless header.detect { |cell| cell =~ pattern }
        end
        yield header
      end
    end
  end
end

class RawAsciiReport < Array
  attr_accessor :sourceurl, :cookie
end

class TextData < String
  attr_accessor :sourceurl, :cookie
end


# This class defines an interface between Form#post and SGMLParser.  Any
# parser classes that are to be used by qute top-level command methods should
# inherit from this class.
class DataObjGen < SGMLParser
  # Data object (i.e. Table or FormList) created by a sublass's 'new' method.
  # This object must have accessors named 'cookie' and 'sourceurl'
  attr_accessor :dataobj

  # Absolute URL from which was retrieved the data that was fed
  # into this object
  attr_reader :sourceurl
  def sourceurl=(url)
    @sourceurl = url
    @dataobj.sourceurl = url
  end

  # Cookie to be passed along to generated object
  attr_reader :cookie
  def cookie=(c)
    @cookie = c
    @dataobj.cookie = c
  end

  # Verify that there is no text left unparsed
  def verify
    if @parsebuf != '' then
      puts "Unparsed data:", @parsebuf
      raise "Parse error: some text still unparsed"
    end
  end
end

# This class breaks the above rule -- it parses the RawAscii report, and as
# such does not inherit from SGMLParser.  Nevertheless, it provides the same
# interface as a DataObjGen would.
class RawAsciiParser
  # The data object for RawAsciiParser is a RawAsciiReport, created by a
  # sublass's 'new' method. This object must have accessors named 'cookie' and
  # 'sourceurl'
  attr_accessor :dataobj

  # Absolute URL from which was retrieved the data that was fed
  # into this object
  attr_reader :sourceurl
  def sourceurl=(url)
    @sourceurl = url
    @dataobj.sourceurl = url
  end

  # Cookie to be passed along to generated object
  attr_reader :cookie
  def cookie=(c)
    @cookie = c
    @dataobj.cookie = c
  end

  # Verify that there is no text left unparsed.  This doesn't make sense for
  # Raw Ascii reports, so we simply never complain.
  def verify
    #p @dataobj
  end

  # Now we move on to the Parser interface
  def initialize
    @rawreport = @dataobj = RawAsciiReport.new
    @parsebuf = ''

    @crntqar = nil
    @crntfield = nil
  end

  def <<(addbuf)
    # add new data to parsebuf
    @parsebuf << addbuf

    # parse as much at the beginning as parsebuf as we can
    loop do
      # peel one line off the beginning of the text buffer and process it
      line = nil
      @parsebuf.sub!(/^.*?\n/) do
        line = $&
        ''
      end or break

      # put this line in the appropriate place
      case line
      when /^(QarId): *(\d*)( UNPUBLISHED)?/
        @crntqar = NonAmbiguousHash.new
        @crntqar[$1] = $2
        @crntqar['Publish'] = 'N' if $3
        @dataobj << @crntqar
      when /^ (\w+): *(.*)/
        @crntqar or raise "RawAscii parse error: #{line}"
        @crntfield = $1
        @crntqar[$1] = $2
      when /^  (.*\n)/
        @crntqar[@crntfield] += $1
      end
    end
  end
end


class FormParser < DataObjGen
  def initialize
    super
    @formlist = @dataobj = FormList.new
    @lastfield = nil    # Refernce to the previously parsed form field
    @lastoption = nil   # Refernce to the previously parsed select option token
  end

  def start_form(token)
    @form = Form.new
    @form.targeturl = @sourceurl.merge(token['action'])
    @formlist << @form
  end

  def start_input(token)
    # create a new field
    field = FormField.new
    field.name = (token['name'] or '')
    field.value = token['value']

    # set the choices and value (and other attributes), depending on type
    case (token['type'] or 'input').downcase
    when 'hidden'
      field.hidden = true
    when 'checkbox'
      field.choices[''] = 'Off'
      field.choices[(token['value'] or 'on')] = (token['value'] or 'On')
      field.value = token['checked'] ? (token['value'] or 'on') : ''
    when 'radio'
      field = (@form[token['name']] or field)
      field.choices[token['value']] = token['value']
      field.value = token['value'] if token['checked']
    when 'password'
      field.password = true
    when 'button'
      field = nil
    end

    # add this field to the form
    @form[field.name] = field if field
  end

  def finish_option
    if @lastoption then
      title = endcapture
      value = @lastoption['value']
      @lastfield.choices[(value or title)] = (title or value)
      @lastfield.value = (value or title) if @lastoption['selected']
      @lastoption = nil
    end
  end

  def start_select(token)
    @form[token['name']] = @lastfield = FormField.new
    # XXX: consider not including 'name' attribute in FormFields, since it is
    # always available as the field's key in the Form
    @lastfield.name = token['name']
    startcapture
  end

  def end_select(token)
    # process text for the previous choice, if there were any
    finish_option

    # set value to first choice if no options were marked as 'selected'
    @lastfield.value = @lastfield.choices.keys[0] unless @lastfield.value
    @lastfield = nil
  end

  def start_option(token)
    # process text for the previous choice, if this isn't the first one
    finish_option

    # save this token for processing at next finish_option
    startcapture
    @lastoption = token
  end

  def start_textarea(token)
    @form[token['name']] = @lastfield = FormField.new
    @lastfield.name = token['name']
    startcapture(pre = true)
  end

  def end_textarea(token)
    @lastfield.value = endcapture
    @lastfield = nil
  end
end

class TableParser < DataObjGen
  def initialize
    super
    @table = @dataobj = Table.new
    @lastrow = TableRow.new
  end

  def verify
    super
    if @table.length < 1 then
      puts endcapture
      raise "No table data"
    end
  end

  def pushlastrow
    if @lastrow.rowtype then
      @table.push(@lastrow)
      @lastrow = TableRow.new
    end
  end

  def pushcolumn
    @lastrow.push(endcapture)
  end

  def table_tag(token)  pushlastrow; @table.push(TableRow.new('edge')); end
  def tr_tag(token)     pushlastrow; end

  def start_b(token)    @lastrow.rowtype = 'header'; end

  def start_td(token)   startcapture; @lastrow.rowtype = 'data'; end
  def end_td(token)     pushcolumn; end

  def start_th(token)   startcapture; @lastrow.rowtype = 'header'; end
  def end_th(token)     pushcolumn; end
end

class TextParser < DataObjGen
  def initialize
    super
    @text = @dataobj = TextData.new('')
  end

  def do_token(token)
    if token.object == 'text' then
      @text << token.to_s
      
      # Render (or remove) Javascript stuff that we can figure out
      @text.gsub!(/alert\((.*?)\);/m) { |s|
        begin
          t = eval $1
          t.gsub!(/^/, '***  ')
          t = ('*' * 70) + "\n" + t + ('*' * 70) + "\n"
        rescue
          t = s
        end
        t
      }
      @text.gsub!(/history.go\(.*?\);/m, '')
      @text.gsub!(/setTimeout\(.*?\);/m, '')

      @text.gsub!(/(.{0,70})(\s|$)/, "\\1\n")  # wrap text at 70 chars
    end
  end

  def start_p(token)
    @text << "\n\n"
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
    fork { exec ENV['EDITOR'] || "vi", file.path }
    Process.wait

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

def Qute::getmainforms(needlogin = false, forcelogin = false)
  formsfile = ENV['HOME'] + '/.qute.forms'
  mainforms = nil
  toolate = Time.now - (24 * 60 * 60 * 7)       # 7 days

  if File.exists? formsfile and File.stat(formsfile).mtime > toolate and not forcelogin then
    # XXX: This may not be correct.  The cookie may have expired, or the main
    # form page may have changed.  We should detect that somehow, re-login,
    # and re-capture the main forms.  Note I have never observed any of these
    # unhandled conditions.
    File.open(formsfile) do |file|
      if (file.lstat.mode & 0066) > 0 then
        puts "Warning: %s permissions too loose" % formsfile
      end
      mainforms = Marshal.load(file)
    end

  else
    # The cached login isn't good.  We'll have to do something about that.

    # webqar2 starting url
    url = 'http://webster.zk3.dec.com/webqar2/WebQar2.pl'

    # If we can do this anonymously, don't force a login -- use the browse
    # mode instead.  If the use asked to log in, or if we are entering,
    # updating, etc... then force a login.
    loginform = nil
    if not needlogin and not forcelogin then
      loginform = Form.new(url).post(FormParser).detect { |form|
        form['UserClass'].value =~ /browse/i
      }
      loginform or raise %Q(WebQar2 login page has changed or is down:\n#{url})
    else
      loginform = Form.new(url).post(FormParser).detect { |form|
        form['Password']
      }
      loginform or raise %Q(WebQar2 login page has changed or is down:\n#{url})

      begin
        # get username
        username = Qute::getline('WebQAR2 Username [%s]: ' % ENV['USER']).chomp
        loginform['Username'].value = username == '' ? ENV['USER'] : username

        # get password
        system('stty -echo')
        loginform['Password'].value = Qute::getline('Password: ').chomp
        puts
      rescue Exception
        # Get off of the prompt line
        puts
        raise
      ensure
        system('stty echo')
      end
    end

    # point to live database
    loginform.targeturl.merge('/webqar2/live/')

    # get past initial alert page, collecting the cookie along the way
    resp, data = loginform.post
    loginform.cookie = $1 if resp['set-cookie'] =~ /^([^']*)/

    # return the main forms
    mainforms = loginform.post(FormParser)
    if not mainforms.detect { |form| form['QarId'] }
      raise "Incorrect username or password?"
    end

    # if this was a real login, save off the forms
    if needlogin or forcelogin then
      File.open(formsfile, 'w') do |file|
        file.chmod(0600)
        Marshal.dump(mainforms, file)
      end
    end
  end

  mainforms
end


class MatchError < RuntimeError
  attr :ptn
  attr :olist
  attr :match
  def initialize(ptn, olist, match = nil)
    @ptn, @olist, @match = ptn, olist, match
  end
end

class MatchAmbiguous < MatchError
  def to_s
    "Option '#{@ptn}' is ambiguous between: #{@match.sort.join ', '}."
  end
end

class MatchNone < MatchError
  def to_s
    "Option '#{@ptn}' must be one of #{@olist.sort.join ', '}."
  end
end

$nonambcache = {}
def Qute::getnonambiguous(ptn, olist)
  # This function chooses exactly one item from optionlist <olist> that
  # matches the pattern <ptn>.  At each stage, if exactly one item matches, it
  # is returned.  If more than one item matches at that stage, it is
  # considered ambiguous, and an exception is raised.  If no items match, we
  # progress to the next stage, which is generally a little "looser".  If
  # there are not more stages, and still no match, we raise an exception.
  match = []
  ptn ||= ''

  # Try cache first
  cacheid = [ olist.hash, ptn.hash ]
  value = $nonambcache[cacheid]
  return value if value

  # Filter empty strings from olist
  olist = olist.select { |item| item != '' }

  # If there aren't caps in the ptn, then let's do a case-insensitive search
  cmplist = if ptn =~ /[A-Z]/
    cmplist = olist   # case sensitive
  else
    cmplist = olist.map { |item| item.downcase }  # case insensitive
  end

  # First stage -- exact match
  olist.each_index { |i|
    return $nonambcache[cacheid] = olist[i] if cmplist[i] == ptn
  }

  # Second stage -- initial match
  olist.each_index { |i|
    cmplist[i][0...ptn.length] == ptn and match << olist[i]
  }
  match.length == 1 and return $nonambcache[cacheid] = match[0]
  match.length >  1 and raise MatchAmbiguous.new(ptn, olist, match)

  # Third stage -- interior match
  olist.each_index { |i|
    cmplist[i].include? ptn and match << olist[i]
  }
  match.length == 1 and return $nonambcache[cacheid] = match[0]
  match.length >  1 and raise MatchAmbiguous.new(ptn, olist, match)

  # Final stage -- regex
  olist.each_index { |i|
    begin
      cmplist[i] =~ /#{ptn}/ and match << olist[i]
    rescue RegexpError
      # If this occurs then probably nothing has been added to the
      # match array at this point.  This workaround is for Ruby 1.6
      # which raises an exception on '?'
      break
    end
  }
  match.length == 1 and return $nonambcache[cacheid] = match[0]
  match.length >  1 and raise MatchAmbiguous.new(ptn, olist, match)

  # Still here? Must not match anything at all...
  raise MatchNone.new(ptn, olist)
end

class NonAmbiguousHash < Hash
  def [](key)
    begin
      realkey = Qute.getnonambiguous(key, self.keys)
    rescue MatchNone
      return nil
    end
    super(realkey)
  end
end


end # module Qute

class String
  def lfit(width) self[0,width].ljust(width) end
  def rfit(width) self[0,width].rjust(width) end

  def format(*hashlist)
    self.gsub(/\{ ([^{}]*?) ([+-]\d*)? \}/x) do
      key, pad = $1, $2.to_i
      value = nil
      hashlist.each do |hash|
        value = hash[key] and break
      end
      value = value.to_s  # This kills the #'s
      if pad < 0 then
        value.lfit(pad.abs)
      elsif pad > 0 then
        value.rfit(pad)
      else
        value
      end
    end
  end
end

class NilClass
  def lfit(width) '#' * width end
  def rfit(width) '#' * width end
end