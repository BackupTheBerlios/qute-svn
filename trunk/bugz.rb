#!/usr/bin/ruby -w
# bugz -- front end for Qute that interacts with Bugzilla
# Copyright:: Copyright (c) Sep 2004, Chris Houser <chouser@bluweb.com>
# License::   GNU General Public License Version 2
# $Id: $

require 'qute'
require 'qutecmd'
require 'pp'

$ZERO = 'bugz'
$QUTEDEBUG = true

def getmainform
  url = 'http://bugs.gentoo.org/query.cgi?format=advanced'

  queryform = Qute::Form.new(url).post(Qute::FormParser.new).detect { |form|
    form['query_format']
  }

  return queryform
end

class BugColumnSet < QuteCmd::NonAmbiguousHash
  @@columns = {
    'ID'                =>  7,
    'Sev'               =>  3,
    'Pri'               =>  2,
    'Plt'               =>  4,
    'Assignee'          => 20,
    'Status'            =>  4,
    'Resolution'        =>  4,
    'Summary'           =>  0,
  }

  def initialize()
    @@columns.each do | name, width |
      self[name] = col = QuteCmd::OutputColumn.new(name)
      col.width = width
    end
  end
end

class BugGrid < QuteCmd::SynopsisGrid
  def initialize(cmdobj)
    super
    @colset = BugColumnSet.new
  end
end

class BugList
  include Enumerable

  def initialize( queryform )
    @bugtable = queryform.post( Qute::TableParser.new )
  end

  def each
    foundbug = false
    @bugtable.eachheader(/ID/) do |header|
      header.eachrecord do |record|
        foundbug = true
        yield record
      end
    end
    foundbug or puts "Zarro Boogs found."
  end
end

class MultiParser
  def initialize( *parsers )
    @parsers = parsers
  end

  def method_missing( method, *args )
    @parsers.each do |parser|
      parser.send( method, *args )
    end
  end
end

class BugData
  attr_accessor :sourceurl, :cookie
  attr_accessor :description, :comments
  attr_accessor :data

  def initialize
    super
    @comments = []
    @data = {}
  end

  def method_missing(method, *args, &block)
    @data.send(method, *args, &block)
  end
end

class BugDataList < Array
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

# Abstract parser for the output of show_bug.cgi or show_bug.cgi?format=multiple
# (aka long_list.cgi), subclassed by BugDataParser and BugDataParserMulti
class BugDataParserA < Qute::SGMLParser
  include Qute::DataObjGen

  def initialize
    super
    @bugdatalist = @dataobj = BugDataList.new
    @bugdata = BugData.new
    @comment = nil
  end

  def end_html(token) @bugdatalist.push(@bugdata); end

  def start_span(token)
    if token['class'] == 'bz_comment'
      @comment = BugComment.new
      startcapture
    end
  end

  def end_span(token)
    return unless @comment      # class != bz_comment
    return if @comment.author   # must be a span tag inside comment text
    return unless endcapture =~ /
      (\d+) \s+                 # bug number
      From \s+ (.*?) \s+        # author
      (\d\d\d\d-\d{1,2}-\d{1,2} # date, time, timezone
      \s+ \d{1,2}:\d\d\s+\S+)
      /x
    @comment.num, @comment.author, @comment.date = $1, $2, $3
  end

  def a_tag(token)
    return unless @comment              # not capturing a comment
    return if @comment.author_email     # already have the email
    return unless token['href'] =~ /^mailto:(.+)/
    @comment.author_email = $1
  end

  def start_pre(token)
    startcapture(true)
  end

  def end_pre(token)
    if @comment
      @comment.text = endcapture
      @bugdata.comments << @comment
      @comment = nil
    else
      desc = endcapture
      @bugdata.description ||= desc
    end
  end
end

# Parser for the output of show_bug.cgi?format=multiple (aka long_list.cgi)
class BugDataParserMulti < BugDataParserA
  def hr_tag(token)   @bugdatalist.push(@bugdata); @bugdata = BugData.new; end

  def start_td(token) startcapture; end
  def end_td(token)
    # check for colon-delimited data
    @bugdata[$1] = $2 if endcapture =~ /(\S.*?)\s*:\s*(.*\S)\s*/
  end
end

# Parser for the output of show_bug.cgi?format=multiple (aka long_list.cgi)
class BugDataParser < BugDataParserA
  
  class SelectList < Array
    attr_reader :multi
    def initialize(multi) 
      @multi = !!multi
      super()
    end
    def to_s
      self.join(', ')
    end
  end

  def initialize
    @label = nil
    @select = nil
    super
  end

  def start_td(token) startcapture; end
  def end_td(token)
    if @label
      s = endcapture.strip
      # handle some labels specially
      case @label
      when 'Bug#'
        s.sub!(/\s.*/, '')
      end
      @bugdata[@label] = s
      @label = nil
    else
      @label = $1 if endcapture =~ /(\S.*?):/
    end
  end

  def start_select(token)
    return unless @label
    @select = SelectList.new(token['multiple'])
    endcapture  # don't start until <option> tag
  end
  def start_option(token)
    return unless @select
    startcapture if @select.multi or token['selected']
  end
  def end_option(token)
    return unless @select and @capture
    @select << endcapture.strip
  end
  def end_select(token)
    return unless @select
    @bugdata[@label] = @select.multi ? @select : @select[0]
    @select = nil
    @label = nil
  end
end

class BugComment
  attr_accessor :num, :author, :author_email, :date, :text

  def to_s
    "------- Comment %s From %s %s -------\n\n%s" % 
    [ @num, @author, @date, @text ]
  end
end

class BugzCommands
  def directory( cmdobj )
    cmdobj.syngrid = BugGrid.new( cmdobj )

    cmdobj.parseargs!
    buglist = BugList.new( cmdobj.queryform )
    cmdobj.syngrid.addrow %w(
      ID Sev Pri Plt Assignee Status Resolution Summary )

    # format each bug found
    QuteCmd.pkgoutput( cmdobj ) do
      headershown = false
      buglist.each do |bug|
        headershown or cmdobj.syngrid.showheader
        headershown = true
        cmdobj.syngrid.showrecord( bug )
      end
    end
  end

  def read( cmdobj )
    cmdobj.parseargs!

    # We can get our ids from query results or direct from the cmdline
    if cmdobj.queryform
      buglist = BugList.new( cmdobj.queryform )
      ids = buglist.map { |i| i['ID'].strip }
    else
      ids = cmdobj.ids
    end

    # show_bug.cgi without format=multiple requires multiple calls to get all
    # the bug data, but format=multiple unfortunately doesn't provide all the
    # data :-(
    bugs = []
    ids.each do |id|
      url = 'http://bugs.gentoo.org/show_bug.cgi?id=' + id
      bugs += Qute::Form.new( url ).post( BugDataParser.new )
    end

    QuteCmd.pkgoutput( cmdobj, true ) do
      first = true
      bugs.each do |bugdata|
        puts '', QuteCmd::hr('='), '' unless first
        first = false
#       puts "%14s : %s" % [ "Bug# #{bugdata['Bug#']}", bugdata['Summary'] ], ''
#       column1 = %w( Assigned\ To Reporter Status Resolution Status\ Whiteboard Keywords URL )
#       column2 = %w( Product Component Hardware OS Version Priority Severity )
#       column3 = %w( CC )
#       column1.each_index do |x|
#         # XXX
#         puts "%14s : %s" % [ k, bugdata[k] ]
#         end
#         puts
#       end
        pp bugdata
        puts "------- Description -------"
        puts
        puts bugdata.description
        puts
        bugdata.comments.each do |bc|
          puts bc
          puts
        end
      end
      puts
    end
  end

  def version( cmdobj )
    puts Qute::VERSIONMSG
  end
end

# Simple options class to use when avoiding query.cgi, only handles bug_id
class OptsBugId
  def validopts(cmdobj)
    return [ 'bug_id', QuteCmd::ArgRequired ]
  end

  def applyopts(cmdobj)
    cmdobj.each(self) do |opt, arg, flags|
      case opt
      when 'bug_id'
        cmdobj.ids << arg
      end
    end
  end
end

# BugzCmdObj subclasses QuteCmdObj to handle specifics of bugzilla
class BugzCmdObj < QuteCmd::QuteCmdObj
  # when query.cgi is required, holds the parsed form for use in OptsFormFields
  attr_reader :queryform

  # when query.cgi is bypassed, contains the list of bug ids, appended to by
  # OptsBugId#applyopts
  attr_accessor :ids

  def initialize(*args)
    @ids = []
    super
  end

  def numberOptStr
    'bug_id'
  end

  def parseargs!
    # If this general heuristic isn't good enough, fetching the query form could
    # be moved to the individual methods of BugzCommands
    if @args.detect { |a| a=~/\D/ }
      @queryform = getmainform
      @optobjlist << QuteCmd::OptsFormFields.new( @queryform )
    else
      @optobjlist << OptsBugId.new
    end
    super
  end
end


# Main program
def main(argv)
  begin
    BugzCmdObj.new( BugzCommands.new, argv )

  rescue Interrupt
    puts "Interrupted by user -- exiting"

  rescue RuntimeError => msg
    raise if $QUTEDEBUG
    puts msg
    puts %Q(There was an error, use "#{$ZERO} help" if needed)

  rescue Exception
    puts "There was an internal error.  Stack trace follows:"
    raise
  end
end

main(ARGV)

