#!/usr/bin/env ruby
# vim: set fileencoding=utf-8:

require "kakasi"
require "MeCab"

class Cambridge
    def initialize
	@mecab_y = MeCab::Tagger.new("-Oyomi")
	@mecab_w = MeCab::Tagger.new("-Owakati")
    end
    def hirakana(str)
	node = @mecab_y.parseToNode(str.encode("EUC-JP"))
	result = "".encode("EUC-JP")
	while node do
	    yomi = node.feature.force_encoding("EUC-JP").split(/,/)[5]
	    if yomi=="*"
		surface = node.surface.force_encoding("EUC-JP").encode("EUC-JP")
		yomi = Kakasi.kakasi("-JH -oeuc", surface).force_encoding("EUC-JP")
	    end
	    result += yomi
	    node = node.next
	end
	result
    end
    def wakati(str)
	begin
	    node = @mecab_w.parse(str).force_encoding("EUC-JP").split
	rescue ArgumentError=>ex
	    Kakasi.kakasi("-w -oeuc", str.encode("EUC-JP")).force_encoding("EUC-JP").split
	end
    end
    def cambridge(str)
	wakati(str).map{|w| self.hirakana(w)}.map{|k|
	    if k.size < 4
		k
	    else
		a = k.split(//)
		[a[0], *(a[1..a.size-2].shuffle), a[a.size-1]].join
	    end
	}.join(" ")
    end
end
camb = Cambridge.new
ARGF.each do|line|
    line.gsub!(/\r|\n/, " ")
    puts camb.cambridge(line)
end

