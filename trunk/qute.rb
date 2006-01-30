#!/usr/local/bin/ruby -w
# $Id$
#
# qute -- Quick Utility for Tracking Errors
#
# Copyright (c) 2002 - 2004 Hewlett-Packard Development Company, L.P.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# * Redistributions of source code must retain the above copyright notice,
#   this list of conditions and the following disclaimer.
# * Redistributions in binary form must reproduce the above copyright
#   notice, this list of conditions and the following disclaimer in the
#   documentation and/or other materials provided with the distribution.
# * Neither the name of the Hewlett-Packard Development Company, L.P.  nor
#   the names of its contributors may be used to endorse or promote products
#   derived from this software without specific prior written permission.
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

module Qute
VERSIONMSG = "qute version #{%Q$Rev$.gsub(/(^.*: | $)/, '')}"

# Parse SGML-like text.  Should be subclassed, with children overriding
# methods of the form start_foo, end_foo, and foo_tag, which will be called
# with a SGMLParser::Token object as a paremeter when any of these tokens are
# encountered in the input stream.  The input stream is fed to SGMLParser
# objects via the << method.
class SGMLParser
  # Bugzilla long_list.cgi outputs a line with <font ="+3>.
  # Using OPTVALRE in OPTSRE helps us handle this situation.
  OPTVALRE = %r{ (?:=\s*"([^"]*)" | =\s*'([^']*)' | =\s*([^\s>]*)) }x
  OPTSRE = %r{ (?:([^\s>=]+) #{OPTVALRE.source}? | #{OPTVALRE.source}) }x

  SGMLRE = %r{
    (\A[^&<]+) |                                # text
   # this next line breaks ruby on Tru64:
    (\A<\W*[^<>=]*(?=<)) |                      # broken text
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
        elsif @matchdata[i+=1] then ['text', '']
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
        # XXX: by not stripping this string, we could see multiple
        # spaces in a row, but I think this is better than the
        # possibility of completely eliminating spaces under other
        # circumstances.  Perhaps the collapsing should be done by
        # CaptureObj instead of the Token?
        CGI.unescapeHTML(@matchdata.to_s.tr_s(" \t\n", ' '))
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
    @pre = false        # does captured text retain its whitespace formatting?
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
        #puts "Processing %s_%s" % [token.object, token.tag]
        self.send('%s_%s' % [token.object, token.tag], token)
        self.send('%s_tag' % [token.tag], token)
      end

      if @capture
        case token.object
        when 'text'
          # text tokens are thrown away unless capture is true, in which
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

# Combination Array and Hash: OrderedHash#[String] accesses as Hash;
# OrderedHash#[Integer] accesses as Array.  OrderedHash#each will return values
# in the order they were added, since it's simply falling back to Array#each
class OrderedHash < Array
  def initialize
    super
    @hash = {}
  end

  def []=(key, val)
    delete key if @hash[key]
    @hash[key] = val
    self << val
  end

  def [](key)
    (key.is_a? String) ? @hash[key] : super
  end

  def delete(key)
    super self[key]     # Array#delete takes val, not key
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

# Each FormField object represents an HTML form element, such as an
# <input>, <textarea>, or <select> element.  They are usually created
# by the FormParser class.
class FormField
  # formal name of this form field
  attr_accessor :name

  # current value of this field
  attr_reader   :value

  # should we hide the existance of this field?
  attr_accessor :hidden

  # should we mask out the value of this field?
  attr_accessor :password

  # extra text describing this field
  attr_accessor :prompt

  # list of choices if this is multiple-choice, such as a <select>
  # element or set of radio buttons.
  attr_reader   :choices

  # true if more than one choice can be used for this field at the
  # same time
  attr_accessor :multiple

  # informal descriptive name of this field
  attr_writer   :title

  def initialize
    @name = nil
    @value = nil
    @hidden = false
    @password = false
    @prompt = nil
    @choices = OrderedHash.new
    @multiple = false
    @title = nil
  end

  # Returns the informal #title, or if none has been set, returns the
  # formal #name of the HTML element.
  def title
    @title or @name
  end

  # Set the current value of the object.  If this FormField has
  # #choices (such as if it's a <select> element or a set of radio
  # buttons), then the value is actually set to one of the valid
  # choices, as determined by Qute.getnonambiguous.
  # 
  # Note that if @multiple is set, then value will always be an array
  # even if newval isn't.
  def value=( newval )
    if newval.is_a? Array
      raise "Attempted to set a non-multiple value to array" unless @multiple
    else
      newval = [ newval ]
    end

    if @choices.length > 0 and (newval.length > 1 or newval[0] != '')
      choicelist = ( @choices + @choices.keys ).uniq
      newval.map! { |v|
        choice = Qute.getnonambiguous(v, choicelist)
        @choices.invert[choice] or choice
      }
    end

    newval = newval[0] unless @multiple
    @value = newval
  end

  def to_s
    if @name.nil? or @name == ''
      ''
    else
      vals = (@multiple && @value) ? @value : [ @value ];
      vals.map { |v|
        '%s=%s' % [CGI.escape(@name), CGI.escape(v || '')]
      }.join('&')
    end
  end
end

# Classes related to forms:
#       FormField - one field in a form
#       Form      - one form in a page, handles posting and marshalling
#       FormList  - list of forms in a page
# 
# The Form class represents a list of FormFields (via OrderedHash), along with
# the methods necessary to post the itself to a CGI.
class Form < OrderedHash
  attr_accessor :sourceurl, :targeturl, :cookie, :method
  @@http = nil

  def initialize(targeturl = nil, prevobj = nil)
    super()
    @method = 'get'
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
    map { |field| field.to_s }.join('&')
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

      # Handle multiple selects
      if field.multiple and field.value
        field.value << value
      else
        field.value = value
      end
    }
  end

  # post form data to CGI @action on server @host
  def post(parser = nil)
    @targeturl or raise "No target url -- cannot post"
    resp = nil

    loop do

      # if a parser was passed in, set it
      # up as the http.post destination object
      if parser then
        # XXX: temporary code to catch clients trying to use the old
        # API for this method:
        parser.is_a? Class and raise(
            "Parameter to From::post must now be an instance of" +
            " a Parser class instead of the class itself." )

        # the new object's sourceurl is our own targeturl
        # this is used for setting the next post's referer
        parser.sourceurl = targeturl
      end

      # connect to web host unless we already have a matching http object
      if not @@http or @@http.address != @targeturl.host then
        if ENV['http_proxy']
          proxyurl = URI::parse(ENV['http_proxy'])
          proxyhost, proxyport = proxyurl.host, proxyurl.port
        end
        @@http = Net::HTTP.Proxy(proxyhost,
          proxyport).new(@targeturl.host, @targeturl.port)
      end

      # send the data
      headers = {
        'Content-Type' => 'application/x-www-form-urlencoded',
        'UserAgent' => 'qute',
        'Referer' => @sourceurl ? @sourceurl.to_s : @targeturl.to_s
      }
      headers['Cookie'] = @cookie if @cookie
      path = @targeturl.path + (@targeturl.query ? '?' + @targeturl.query : '')
#     puts "\n--------------------\nQuery\n--------------------\n"
#     p [ path, querystring, headers ]
#     puts "--------------------\nEnd Query\n--------------------\n"
      if @method == 'get' or querystring == ''
          querystring == '' or path += '?' + querystring
          resp = @@http.get(path, headers, parser)
      else
          resp = @@http.post(path, querystring, headers, parser)
      end

      # 1.6.8 / 1.8.0 compatibility: 
      # 1.6.8 returns [resp,data] where 1.8.0 returns only resp
      if RUBY_VERSION < "1.8"
          resp = resp[0]
      end

#     puts "\n--------------------\nResponse\n--------------------\n"
#     p resp
#     puts resp.body
#     puts "--------------------\nEnd Response\n--------------------\n"

      if resp.header['location']
        @targeturl = @targeturl.merge( resp.header['location'] )
      else
        break
      end

    end

    # return value depends on if a parser was passed in
    if parser then
      # set the data object generator's cookie
      parser.cookie = $1 if resp['set-cookie'] =~ /^([^;]*)/

      # return the data object created by the parser instance
      parser.verify
      return parser.dataobj
    else
      # return the raw response data from the web server
      return [resp, resp.body]
    end
  end

  def inspect
    "( @@http = #{@@http.inspect}\n" +
    "  @sourceurl = #{@sourceurl.inspect}\n" +
    "  @targeturl = #{@targeturl.inspect}\n" +
    "  @cookie = #{@cookie.inspect}\n" +
    "  @method = #{@method.inspect}\n  " +
    "  #{super}\n" +
    ")"
  end
end

# The FormList class keeps track of a common sourceurl and cookie for a set of Forms
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

# The TableRow class provides storage for a list of values (columns) for a given
# row in a Table.  It keeps track of whether the row consists of header or data,
# and where the row appears in the Table.
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

# A TableRecord allows access to a record keyed by headers
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

# Classes related to table management:
#       TableRow    - one row of a table
#       TableRecord - one record, comprising N rows
#       Table       - entire web page
#
# A Table is an array of TableRows.  It keeps track of a sourceurl and cookie
# for the entire table, plus provides easy access to all the header rows.
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

  # Iterate through header rows that contain a cell matching one of the given
  # patterns
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

# TextData is just a String with an associated sourceurl and cookie, similar to 
# Table and Form
class TextData < String
  attr_accessor :sourceurl, :cookie
end


# This module is a mix-in, defining pieces of a Parser interface.  The
# main use of classes mixing in DataObjGen will be as the first
# parameter to a Form#post call.  This is not a sub-class of
# SGMLParser because it may be useful to create a Parser class that
# provides a DataObjGen interface without parsing any SGML at all.
# This mix-in is used by FormParser, TableParser, and TextParser.
module DataObjGen
  # Data object (i.e. Table or FormList) created by a subclass's 'new' method.
  # This object must have accessors named 'cookie' and 'sourceurl'.
  attr_accessor :dataobj

  # Absolute URL from which the data was retrieved, that was then fed
  # into this object.
  attr_reader :sourceurl

  # When this #sourceurl is set, set the #dataobj's #sourceurl as well.
  def sourceurl=(url)
    @sourceurl = url
    @dataobj.sourceurl = url
  end

  # Cookie to be passed along to generated object.
  attr_reader :cookie

  # When this #cookie is set, set the #dataobj's #cookie as well.
  def cookie=(c)
    @cookie = c
    @dataobj.cookie = c
  end

  # Verify that there is no text left unparsed.
  def verify
    if @parsebuf != '' then
      puts "Unparsed data:", @parsebuf
      raise "Parse error: some text still unparsed"
    end
  end
end # module DataObjGen

class FormParser < SGMLParser
  include DataObjGen

  def initialize
    super
    @formlist = @dataobj = FormList.new
    @lastfield = nil    # Reference to the previously parsed form field
    @lastoption = nil   # Reference to the previously parsed select option token
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
    # XXX Bugzilla has a few submit buttons on its main query page (at
    # least at Gentoo and probably other places).  The first and
    # second are equivalent and nameless.  The remaining submit
    # buttons are for manipulating the boolean charts...  If one of
    # those gets into the posted form then we'll get back another
    # query page instead of the results page.
    when 'submit'
      field = nil if @form['']
    end

    # add this field to the form
    @form[field.name] = field if field
  end

  def finish_option
    if @lastoption then
      title = endcapture.strip
      value = @lastoption['value']
      @lastfield.choices[(value or title)] = (title or value)
      if @lastoption['selected']
        if @lastfield.multiple and @lastfield.value
          @lastfield.value << (value or title)
        else
          @lastfield.value = (value or title)
        end
      end
      @lastoption = nil
    end
  end

  def start_select(token)
    @form[token['name']] = @lastfield = FormField.new
    # XXX: consider not including 'name' attribute in FormFields, since it is
    # always available as the field's key in the Form
    @lastfield.name = token['name']
    @lastfield.multiple = ( token['multiple'] and token['multiple'] != 'no' )
    startcapture
  end

  def end_select(token)
    # process text for the previous choice, if there were any
    finish_option

    # if no options were marked 'selected' then set a default value
    if @lastfield
      if @lastfield.multiple
        # default for multiple is the empty list
        @lastfield.value ||= []
      else
        # default for non-multiple is the first in the list
        @lastfield.value ||= @lastfield.choices.keys[0]
      end
    end
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
    name = token['name'] || 'UnnamedTextarea'
    @form[name] = @lastfield = FormField.new
    @lastfield.name = name
    startcapture(pre = true)
  end

  def end_textarea(token)
    @lastfield.value = endcapture
    @lastfield = nil
  end
end

class TableParser < SGMLParser
  include DataObjGen

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

class TextParser < SGMLParser
  include DataObjGen

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
# This function chooses exactly one string from option list _olist_
# that matches the pattern _ptn_.  It does this through a series of
# stages.  At each stage, if exactly one item matches, it is returned.
# If more than one item matches at that stage, it is considered
# ambiguous, and a Qute::MatchAmbiguous exception is raised.  If no
# items match, we progress to the next stage, which is generally a
# little "looser".  If there are no more stages, and still no match,
# we raise a Qute::MatchNone exception.
def Qute::getnonambiguous(ptn, olist)
  match = []
  ptn ||= ''

  # Try cache first
  cacheid = [ olist.hash, ptn.hash ]
  value = $nonambcache[cacheid] and return value

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


end # module Qute
