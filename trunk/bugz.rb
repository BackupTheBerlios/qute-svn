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

class BugData < Hash
  attr_accessor :sourceurl, :cookie
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

class BugDataParser < Qute::SGMLParser
  include Qute::DataObjGen

  def initialize
    super
    @bugdatalist = @dataobj = BugDataList.new
    @bugdata = BugData.new
  end

  def hr_tag(token)   @bugdatalist.push(@bugdata); @bugdata = BugData.new; end

  def start_td(token) startcapture; end
  def end_td(token)
    # check for colon-delimited data
    @bugdata[$1] = $2 if endcapture =~ /(\S.*?)\s*:\s*(.*\S)\s*/
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
    if cmdobj.queryform
      buglist = BugList.new( cmdobj.queryform )
      ids = buglist.map { |i| i['ID'].strip }
    else
      ids = cmdobj.ids
    end
    url = 'http://bugs.gentoo.org/long_list.cgi?buglist=' + ids.join(',')
    bugs = Qute::Form.new( url ).post( BugDataParser.new )

    QuteCmd.pkgoutput( cmdobj ) do
      bugs.each do |bugdata|
        longkey = 0
        # really need something better than pp ;-)
        pp bugdata
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
    super(*args)
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

