#!/usr/bin/ruby -w
# bugz -- front end for Qute that interacts with Bugzilla
# Copyright:: Copyright (c) Sep 2004, Chris Houser <chouser@bluweb.com>
# License::   GNU General Public License Version 2
# $Id: $

require 'qute'
require 'qutecmd'

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

class BugText
  def initialize( queryform )
    table = Qute::TableParser.new
    form  = Qute::FormParser.new
    @bugtext = queryform.post( MultiParser.new( table, form ) )

    p form.dataobj
    p table.dataobj
  end

  # XXX this definitely isn't complete
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
    # XXX need a new grid probably
    cmdobj.parseargs!
    bugtext = BugText.new( cmdobj.queryform )
    # XXX need to finish BugText then can do something with it here
  end

  def version( cmdobj )
    puts Qute::VERSIONMSG
  end
end

class BugzCmdObj < QuteCmd::QuteCmdObj
  attr_reader :queryform

  def numberOptStr
    'bug_id'
  end

  def parseargs!
    @queryform = getmainform
    @optobjlist << QuteCmd::OptsFormFields.new( @queryform )
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

