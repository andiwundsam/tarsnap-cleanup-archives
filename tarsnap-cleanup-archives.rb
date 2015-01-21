#!/usr/bin/ruby

require 'pp'
require 'date'
require 'optparse'
require 'set'

Selector = Struct.new("Selector", :name, :func)
Cand = Struct.new("Cand", :name, :date)

dry_run = false
verbose = false
keyfile = nil

selectors = [
    Selector.new("yearly", lambda { |old, new| new.year > old.year }),
    Selector.new("monthly", lambda { |old, new| new.year > old.year || new.month > old.month }),
    Selector.new("weekly", lambda { |old, new| new.cwyear > old.cwyear || new.cweek > old.cweek }),
    Selector.new("daily",  lambda { |old, new| new.year > old.year || new.yday > old.yday }),
    Selector.new("any", lambda { |old, new| true }),
]

def bt(command)
    res = `#{command}`.split("\n")
    if $?.to_i > 0
        raise "Command #{command} failed with error #{$?.to_i}"
    end
    res
end

options = {}
o = OptionParser.new do |opts|
    opts.banner = "Usage: cleanup-tarsnap [options] <PREFIX> [<PREFIX>...]"

    opts.on("-k", "--keyfile STR", "Specify keyfile for tarsnap") do |v|
        keyfile = v
    end

    opts.on("-v", "--[no-]verbose", "Run verbosely") do |v|
        verbose = v
    end

    opts.on("-n", "--[no-]dry-run", "No real changes") do |v|
        dry_run = v
    end

    selectors.each do |s|
        opts.on("-#{s.name[0]}", "--#{s.name} N", Integer, "Number of #{s.name} backups to keep") { |v|
         options[s.name.to_sym] = v
        }
    end
end
o.parse!

if selectors.select {|s| options.has_key?(s.name.to_sym) }.size == 0
    STDERR.puts "Must give at least one selector!\n"
    STDERR.puts o.help()
    exit(2)
end

if ARGV.empty?
    STDERR.puts o.help()
    exit(1)
end

keyfile_opt=if keyfile then "--keyfile #{keyfile}" else "" end

archives=bt("tarsnap --list-archives #{keyfile_opt}")

#archives =["dev", 
#    "dev_2014-01-01_19-20-01", 
#    "dev_2015-01-01_19-20-01", 
#    "dev_2015-01-08_19-20-01", 
#    "dev_2015-01-09_19-20-01", "dev_2015-01-17_19-20-01", "dev_2015-01-18_19-20-01", "dev_2015-01-19_19-20-01", "dev_2015-01-19_16-20-00", "dev_2015-01-19_18-00-00", "dev_2015-01-19_15-38-12",
#    "dev_2015-01-19_16-03-30", "dev_2015-01-19_15-37-50", "dev_2015-01-19_16-40-00", "dev_2015-01-19_19-00-00", "dev_2015-01-19_16-03-58", "dev_2015-01-19_17-40-00", "dev_2015-01-19_18-20-00",
#    "dev_2015-01-19_20-00-00", "dev_2015-01-19_19-40-00", "dev_2015-01-19_17-00-00", "dev_2015-01-19_17-20-00", "dev_2015-01-19_18-40-00"]

ARGV.each do |prefix|
    re = /^#{prefix}_(\d+)-(\d+)-(\d+)_(\d+)-(\d+)-(\d+)$/
    cands = archives.select {|a| re.match(a) }.map {|a|
        (year, month, day, hour, min, sec) = re.match(a)[1..-1].map {|s| s.to_i }
        date = DateTime.new(year, month, day, hour, min, sec)
        Cand.new(a, date)
    }.sort {|a,b| a.date <=> b.date }

    if cands.empty?
        STDERR.puts "No archives found with prefix #{prefix}"
        next
    end

    marked = { cands[-1].name => "newest" }
    # pairs of old and new cands. The new one is the one being tested
    pairs = cands[0..-2].zip(cands[1..-1]).reverse

    selectors.reverse.each do |sel|
        to_mark = options[sel.name.to_sym]
        if to_mark and to_mark > 0
           pairs.each do |old, new|
                if not marked.has_key?(old.name) and sel.func.call(old.date, new.date)
                    marked[old.name] = sel.name
                    to_mark -= 1
                    if to_mark == 0
                        break
                    end
                end
            end
        end
    end
    to_delete = cands.map{|c| c.name }.reject { |name| marked.has_key?(name) }
    to_keep = cands.map{|c| c.name }.select { |name| marked.has_key?(name) }

    if verbose
        puts "Archives for Prefix #{prefix}"
        len=cands.map {|c| c.name.size }.max
        puts "len: #{len}"
        cands.each do |c|
            printf "%19s  %#{len}s  %s\n", c.date.strftime("%Y-%m-%d %H:%M:%S"), c.name, marked.has_key?(c.name) ? "KEEP #{marked[c.name]}" : "DELETE"
        end
    end

    to_delete.each do |n|
        if not dry_run
            bt("tarsnap -d #{keyfile_opt} -f #{n}")
        else
            puts("Delete: #{n}")
        end
    end
end
