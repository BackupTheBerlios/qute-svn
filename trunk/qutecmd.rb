#!/usr/local/bin/ruby -w
# $Id$
#
# qutecmd -- Qute library for command-line utilities
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

require 'qute'

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

module QuteCmd

begin
  require 'readline'
  Readline.completion_proc = proc {}
  #debug "loaded readline"
rescue LoadError
  #debug "failed to load readline"
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
    $defout.print prompt
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

end # module QuteCmd
