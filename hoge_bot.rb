#!/home/komuro/local/bin/ruby-1.9.1
# vim: set fileencoding=utf-8:
require "pit"
require "twitter"
require "pp"
require "kakasi"
require "MeCab"
require "uri"
require "net/http"

SLEEP_UNIT = 60
REPLY_INTERVAL = 1
TIMELINE_INTERVAL = 13
DATA_DIR = "./data/"

def serialize(obj)
    return <<EOM
# vim: set fileencoding=utf-8:
# vim: set ft=ruby sw=2 ts=2:
#{obj.pretty_inspect}
EOM
end
class Bot
    USERINFO = DATA_DIR+"users"
    BOTDIC = DATA_DIR+"botdic"
    UPDATES = DATA_DIR+"updates"
    REPLIES = DATA_DIR+"replies"
    ORIGINS = DATA_DIR+"origins"
    DICVAR_REG = /\|([^|]+)\|/;
    class Command
        def initialize(commands)
            @commands = commands
        end
        def trigger(line)
            name, *args = line.split
            if command = @commands[name]
                command[args]
            else
                false
            end
        end
    end
    class Dictionary
        def initialize
            @dic = eval(File.read(BOTDIC))
        end
        def get(key)
            if @dic[key]
                values = @dic[key]
                value = values[rand(values.size)]
            else
                value = ""
            end
            value.gsub(DICVAR_REG){
                if $1==key
                    $1
                else
                    self.get($1)
                end
            }
        end
        def set(key, value)
            @dic[key] = [value]
        end
        def put(key, value)
            unless @dic.key?(key)
                @dic[key] = []
            end
            @dic[key].push(value)
        end
    end
    def initialize(botname)
        @botname = botname
        @pitname = "twitter-#{@botname}"
        @pit = Pit.get(@pitname, :require => {
            "author" => "author id",
            "username" => "bot id or email",
            "password" => "bot password"
        })
        unless File.directory?(DATA_DIR)
            Dir.mkdir(DATA_DIR)
        end
        unless File.exist?(USERINFO)
            File.open(USERINFO, "w"){|file|file.puts("{}")}
        end
        @users = eval(File.read(USERINFO)) || {}
        unless File.exist?(REPLIES)
            File.open(REPLIES, "w"){|file|file.puts("{}")}
        end
        @replies = eval(File.read(REPLIES)) || {}
        unless File.exist?(ORIGINS)
            File.open(ORIGINS, "w"){|file|file.puts("[]")}
        end
        @origins = eval(File.read(ORIGINS)) || []

        @dic = Dictionary.new
        @dic.set("author", @pit["author"])
        @dic.set("botname", @botname)

        @mecab_w = MeCab::Tagger.new("-Owakati")
        @mecab_y = MeCab::Tagger.new("-Oyomi")

        Net::HTTP.version_1_2

        @command = Command.new({
            "suspend" => proc{|name|
                #@users.find{|i|i[:name]==name}[:status] = :suspended
            },
        })

        begin
            httpauth = Twitter::HTTPAuth.new(@pit["username"], @pit["password"])
            @client = Twitter::Base.new(httpauth)
        rescue Twitter::General=>ex
            self.error(ex)
            STDERR.puts "Twitter is down."
            exit(1)
        end
    end
    def scan_replies
        begin
            replies = @client.replies.reject{|r| @replies.key?(r.id)}

            if replies.size>0
                replies.each{|reply|
                    r = @replies[reply.id] = {
                        :user_id => reply.user.id,
                        :name => reply.user.screen_name,
                        :text => reply.text,
                    }
                    text = r[:text].gsub(/@#@botname\s*/, "")
                    if r[:name]==@pit["author"] && /`(.+)`/ =~ text
                        unless @command.trigger($1)
                            self.update("@#{@pit["author"]} `#{$1}` failed")
                        end
                    else
                        self.reply(r[:name], text, reply.id)
                    end
                }
                File.open(REPLIES, "w"){|file|
                    file.puts(serialize(@replies))
                }
            end
        rescue Twitter::General=>ex
            self.error(ex)
        end
    end
    def bitly(uri)
        begin
            encode = URI.encode(uri)
            Net::HTTP.start("bit.ly", 80){|http|
                res = http.get("/api?url=#{encode}")
                res.body
            }
        rescue Net::ProtocolError=>ex
            self.error(ex)
        end
    end
    def hirakana(str)
        node = @mecab_y.parseToNode(str)
        result = ""
        while node do
            yomi = node.feature.force_encoding("EUC-JP").split(/,/)[5]
            if yomi=="*"
                yomi = Kakasi.kakasi("-JH -oeuc", node.surface.force_encoding("EUC-JP")).force_encoding("EUC-JP")
            end
            result += yomi
            node = node.next
        end
        result
    end
    def wakati(str)
        euc = str.encode("EUC-JP")
        begin
            node = @mecab_w.parse(euc).force_encoding("EUC-JP").split
        rescue ArgumentError=>ex
            Kakasi.kakasi("-w -oeuc", euc).force_encoding("EUC-JP").split
        end
    end
    def cambridge(str)
        begin
            wakati(str.gsub(/\n|\r/, " ")).map{|w| self.hirakana(w)}.map{|k|
                if k.size < 4
                    k
                else
                    a = k.split(//)
                    [a[0], *(a[1..-2].shuffle), a[-1]].join
                end
            }.join(" ")
        rescue =>ex
            @dic.get("no-cambridge")
        end
    end
    def scan_timeline
        begin
            timeline = @client.friends_timeline.reject{|t|
                t.user.screen_name==@botname || @origins.index(t.id)
            }
            if timeline.size > 0
                pick = timeline[rand(timeline.size)]
                name,text,id = pick.user.screen_name, pick.text, pick.id
                @origins << id
                self.put_origins
                bitly = self.bitly("http://twitter.com/#{name}/status/#{id}")
                self.update("#{self.cambridge(text)} #{bitly}")
            end
        rescue Twitter::General=>ex
            self.error(ex)
        end
    end
    def scan_followers
        begin
            new = @client.followers.map{|data|
                if !@users.key?(data.id)
                    user = @users[data.id] = {
                        :name => data.screen_name,
                        :count_follow => 1,
                        :count_remove => 0,
                        :status => :followed,
                        :friends_count => data.friend_count,
                        :followers_count => data.followers_count,
                    }
                    self.put_users
                    #self.follow(data.id)
                else
                    if (user=@users[data.id])[:status] == :removed
                        user[:status] = :followed
                        user[:count_follow] += 1
                        self.put_users
                        #self.follow(data.id)
                    end
                end
                data.id
            }
            @users.each do|key,value|
                if !new.include?(key)
                    @users[key][:status] = :removed
                    @users[key][:count_remove] += 1
                    self.put_users
                    self.remove(key)
                end
            end
        rescue Twitter::General=>ex
            self.error(ex)
        end
    end
    def follow(id)
        begin
            @client.friendship_create(id, true)
            self.put_users
        rescue Twitter::General=>ex
            error = ex.data["error"]
            if error && /suspended/ =~ error
                @users[id][:status] = :suspended
                self.put_users
            else
                self.error(ex)
            end
            self.error(ex)
        end
    end
    def remove(id)
        begin
            @client.friendship_destroy(id)
            self.put_users
        rescue Twitter::General=>ex
            error = ex.data["error"]
            if error && /suspended/ =~ error
                @users[id][:status] = :suspended
                self.put_users
            elsif error && /You are not friends/ =~ error
                self.put_users
            else
                self.error(ex)
            end
        end
    end
    def reply(name, text, reply_id)
        if name != @botname && !@origins.index(reply_id)
            @origins << reply_id
            self.put_origins
            self.update("@#{name} #{self.cambridge(text)}", reply_id)
        end
    end
    def update(status, reply_id=nil)
        File.open(UPDATES, "a"){|file|
            file.puts("#{Time.now} #{status}")
        }
        begin
            if reply_id
                @client.update(status.encode("UTF-8"), :in_reply_to_status_id=>reply_id)
            else
                @client.update(status.encode("UTF-8"))
            end
        rescue Twitter::General=>ex
            self.error(ex)
        end
    end
    def error(ex)
        msg = ex.backtrace.join("\n")
        STDERR.puts(ex.inspect)
        STDERR.puts(msg)
        File.open(DATA_DIR+"error", "a"){|file|
            file.puts("#{Time.now} #{msg}")
        }
    end
    def put_users
        File.open(USERINFO, "w"){|file|
            file.puts(serialize(@users))
        }
    end
    def put_origins
        File.open(ORIGINS, "w"){|file|
            file.puts(serialize(@origins))
        }
    end
end
def start(exec_time = 24*60*60) # 24 hours
    begin
        bot = Bot.new("cmriadbge_bot")
        start = Time.now
        timeline_count = 0
        while (Time.now - start) < exec_time
            bot.scan_replies
            if (timeline_count+=1) == 1
                bot.scan_timeline
                bot.scan_followers
            elsif timeline_count == TIMELINE_INTERVAL
                timeline_count = 0
            end
            sleep SLEEP_UNIT
        end
        bot.put_users
    rescue => ex
        STDERR.puts(ex)
        bot.error(ex)
    end
end
start(57*60)

# vim: set sw=4 ts=4 et:
