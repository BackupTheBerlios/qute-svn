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

  queryform = Qute::Form.new(url).post(Qute::FormParser).detect { |form|
    form['query_format']
  }

  return queryform
end

class BugList
  def initialize( queryform )
    @bugtable = queryform.post( Qute::TableParser )
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

class BugzCommands
  def directory( cmdobj )
    #cmdobj.need_queryform = true
    cmdobj.syngrid = QuteCmd::SynopsisGrid.new( cmdobj )

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

