#!/usr/bin/ruby -w
# bugz -- front end for Qute that interacts with Bugzilla
# Copyright:: Copyright (c) Sep 2004, Chris Houser <chouser@bluweb.com>
# License::   GNU General Public License Version 2
# $Id: $

require 'qute'
require 'qutecmd'

$ZERO = 'bugz'
$QUTEDEBUG = true

url = 'http://bugs.gentoo.org/query.cgi?format=advanced'

queryform = Qute::Form.new(url).post(Qute::FormParser).detect { |form|
  form['query_format']
}

queryform['short_desc'].value = 'vim'

resp, data = queryform.post

puts resp.body

#p resp
#p resp.methods
#resp.header.each_header do |key, val|
#  print "#{key}: #{val}\n"
#end
#puts resp.header['location']

#puts resp.body

__END__

bugtable = queryform.post(Qute::TableParser)

p bugtable

