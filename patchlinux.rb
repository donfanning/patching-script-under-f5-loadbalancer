require 'net/ssh/telnet'
require 'ridley'
require 'ap'
require 'sqlite3'
require 'colorize'
require 'highline/import'
require 'open3'
require 'trollop'
require 'pp'
require 'f5-icontrol'

Ridley::Logging.logger.level = Logger.const_get 'ERROR'
ridley = Ridley.from_chef_config('/home/user/.chef/knife.rb')


def prompt(*args)
  print(*args)
  gets
end

def highlowhost(host)
    highlowhost = host.split(".")
    oddeven = highlowhost[0].last(2).to_i
    return oddeven
end

class String
	def last(n)
		self[-n..-1] || self
	end
end

date = (Date.today-1).strftime("%Y%m%d").to_s

opts = Trollop::options do
	opt :u, "user", :type => :string
	opt :k, "Patch Kernel"
	opt :r, "Reboot after patching"
	opt :search, "Chef parameters to search for targets", :type => :string
end

f5user = opts[:u]
user = "#{f5user}@domain"
pass = ask("Enter your DOMAIN password: ") { |q| q.echo = "*" }
ridley_search = opts[:search].to_s
patch_date = date
kernel_patch = opts[:k]
reboot_server = opts[:r]

if kernel_patch == true
	kflg = "-k"
else 
	kflg = ""
end

if reboot_server == true
	rflg = "-r"
else
	rflg = ""
end

cmdline = "yum -y update"

nodes = ridley.search(:node, "#{ridley_search}")
nodenames = nodes.map { |node| node.name }


##############

def die(msg)
  puts msg
  exit
end

def checkChefIPAddr(nodename)
	ridley2 = Ridley.from_chef_config('/home/user/.chef/knife.rb')
	nodedata = ridley2.search(:node, "name:#{nodename}")
	ipaddr = nodedata.map { |node| node.automatic.ipaddress }
	return ipaddr
end

def getF5port(ipaddress)
	ipaddr_s = ipaddress[0].to_s
	db = SQLite3::Database.new "f5_mobile.sqlite3"
	row = db.execute("SELECT ipport from members where ipaddr = '#{ipaddr_s}'")
	return row
	db.close
end

def getF5pool(ipaddress)
	ipaddr_s = ipaddress[0].to_s
	db = SQLite3::Database.new "f5_mobile.sqlite3"
    row = db.execute("SELECT bigipaddr,pool,ipport FROM members WHERE ipaddr = '#{ipaddr_s}'")
	return row
	db.close
end

def getF5lb(pool)
	pool_s = pool.to_s
    db = SQLite3::Database.new "f5_mobile.sqlite3"
    row = db.get_first_value("SELECT bigipaddr from members where pool = '#{pool_s}'")
    return row
  	db.close
end

def disableF5member(host,pool,member,port,f5user,pass)
	#puts "disablef5: #{pool}:#{member}:#{port}"
	targetmember = member.to_s
	targetport = port.to_s
	db = SQLite3::Database.new "f5_mobile.sqlite3"
	state = ""
	db.execute("SELECT state FROM members WHERE pool = '#{pool}' AND ipaddr = '#{member}' AND ipport = '#{port}'") do |row|
	  state = row.to_s
	end
	oddeven = highlowhost(host)
	bigip = F5::IControl.new(host, f5user, pass, ["System.Failover", "Management.Partition", "LocalLB.Pool", "LocalLB.PoolMember"]).get_interfaces
	failover = bigip["System.Failover"].get_failover_state()

    if failover =~ /FAILOVER_STATE_STANDBY/
    	puts "This LTM is currently the standby."
        if oddeven.odd?
        	oldhost = host.split(".")
            oddhost = oldhost[0][-2..-1]
            oddhost.to_i
            evenhost = oddhost.to_i + 1
            evenhost = evenhost.to_s.rjust(2,'0')
            newhost = host.sub(oddhost,evenhost)
            host = newhost
            puts "Switching to Active LTM: #{host}"
            bigip = F5::IControl.new(host, f5user, pass, ["System.Failover", "Management.Partition", "LocalLB.Pool", "LocalLB.PoolMember"]).get_interfaces
            failover = bigip["System.Failover"].get_failover_state()
        end
        if oddeven.even?
        	oldhost = host.split(".")
            evenhost = oldhost[0][-2..-1]
            evenhost.to_i
            oddhost = evenhost.to_i - 1
            oddhost = oddhost.to_s.rjust(2,'0')
            newhost = host.sub(evenhost,oddhost)
            host = newhost
            puts "Switching to Active LTM: #{host}"
            bigip = F5::IControl.new(host, f5user, pass, ["System.Failover", "Management.Partition", "LocalLB.Pool", "LocalLB.PoolMember"]).get_interfaces
            failover = bigip["System.Failover"].get_failover_state()
        end
    end 
		
	if failover =~ /FAILOVER_STATE_ACTIVE/
		puts "Gathering current state..."
		bigip["LocalLB.PoolMember"].get_session_enabled_state([pool])[0].each do |member|
			memberaddress = member['member']['address'].to_s
			memberport = member['member']['port'].to_s
			session_state = member['session_state']
			if memberaddress.eql?(targetmember) && memberport.eql?(targetport)
				$pre_session_enabled_state = session_state
			end
		end
		
		memberobj = Struct.new(:address, :port) do
		  def to_hash
		      { 'address' => self.address, 'port' => self.port }
		  end
		end
		memberdef = memberobj.new(targetmember, targetport)
		
		member_state = 'STATE_DISABLED'
		member_session_state = {
			'member' 		=> memberdef.to_hash,
			'session_state' => member_state,
		}
		member_session_state_list = [member_session_state]
		member_session_state_lists = [member_session_state_list]
		
		bigip["LocalLB.PoolMember"].set_session_enabled_state([pool], member_session_state_lists)
		bigip["LocalLB.PoolMember"].get_session_enabled_state([pool])[0].each do |member|
			memberaddress = member['member']['address'].to_s
			memberport = member['member']['port'].to_s
			session_state = member['session_state']
			if memberaddress.eql?(targetmember) && memberport.eql?(targetport)
				$post_session_enabled_state = session_state
			end
		end
			
			
    end
    puts
    if $post_session_enabled_state =~ /DISABLED/
        puts "Pool Member DISABLED {dbg:#{$pre_session_enabled_state}::#{$post_session_enabled_state}}".green
    else
    	puts "Pool Member Disable Failed {dbg:#{$pre_session_enabled_state}::#{$post_session_enabled_state}}".red
    end
end

def enableF5member(host,pool,member,port,f5user,pass)
	targetmember = member.to_s
	targetport = port.to_s
	db = SQLite3::Database.new "f5_mobile.sqlite3"
	state = ""
	db.execute("SELECT state FROM members WHERE pool = '#{pool}' AND ipaddr = '#{member}' AND ipport = '#{port}'") do |row|
	  state = row.to_s
	end
	oddeven = highlowhost(host)
	bigip = F5::IControl.new(host, f5user, pass, ["System.Failover", "Management.Partition", "LocalLB.Pool", "LocalLB.PoolMember"]).get_interfaces
	failover = bigip["System.Failover"].get_failover_state()

    if failover =~ /FAILOVER_STATE_STANDBY/
    	puts "This LTM is currently the standby."
        if oddeven.odd?
        	oldhost = host.split(".")
            oddhost = oldhost[0][-2..-1]
            oddhost.to_i
            evenhost = oddhost.to_i + 1
            evenhost = evenhost.to_s.rjust(2,'0')
            newhost = host.sub(oddhost,evenhost)
            host = newhost
            puts "Switching to Active LTM: #{host}"
            bigip = F5::IControl.new(host, f5user, pass, ["System.Failover", "Management.Partition", "LocalLB.Pool", "LocalLB.PoolMember"]).get_interfaces
            failover = bigip["System.Failover"].get_failover_state()
        end
        if oddeven.even?
        	oldhost = host.split(".")
            evenhost = oldhost[0][-2..-1]
            evenhost.to_i
            oddhost = evenhost.to_i - 1
            oddhost = oddhost.to_s.rjust(2,'0')
            newhost = host.sub(evenhost,oddhost)
            host = newhost
            puts "Switching to Active LTM: #{host}"
            bigip = F5::IControl.new(host, f5user, pass, ["System.Failover", "Management.Partition", "LocalLB.Pool", "LocalLB.PoolMember"]).get_interfaces
            failover = bigip["System.Failover"].get_failover_state()
        end
    end 
		
	if failover =~ /FAILOVER_STATE_ACTIVE/
		puts "Gathering current state..."
		bigip["LocalLB.PoolMember"].get_session_enabled_state([pool])[0].each do |member|
			memberaddress = member['member']['address'].to_s
			memberport = member['member']['port'].to_s
			session_state = member['session_state']
			if memberaddress.eql?(targetmember) && memberport.eql?(targetport)
				$pre_session_enabled_state = session_state
			end
		end
		
		memberobj = Struct.new(:address, :port) do
		  def to_hash
		      { 'address' => self.address, 'port' => self.port }
		  end
		end
		memberdef = memberobj.new(targetmember, targetport)
		
		member_state = 'STATE_ENABLED'
		member_session_state = {
			'member' 		=> memberdef.to_hash,
			'session_state' => member_state,
		}
		member_session_state_list = [member_session_state]
		member_session_state_lists = [member_session_state_list]
		
		bigip["LocalLB.PoolMember"].set_session_enabled_state([pool], member_session_state_lists)
		bigip["LocalLB.PoolMember"].get_session_enabled_state([pool])[0].each do |member|
			memberaddress = member['member']['address'].to_s
			memberport = member['member']['port'].to_s
			session_state = member['session_state']
			if memberaddress.eql?(targetmember) && memberport.eql?(targetport)
				$post_session_enabled_state = session_state
			end
		end
			
			
    end
    puts
    if $post_session_enabled_state =~ /ENABLED/
        puts "Pool Member ENABLED {dbg:#{$pre_session_enabled_state}::#{$post_session_enabled_state}}".green
    else
    	puts "Pool Member Enable Failed {dbg:#{$pre_session_enabled_state}::#{$post_session_enabled_state}}".red
    end
end

def noop
end

nodes = nodenames.sort
nodes.each do |nodename|
	s = Net::SSH::Telnet.new(
		"Host" => "#{nodename}",
		"Username" => "#{user}",
		"Password" => "#{pass}"
	)
	ipaddr = checkChefIPAddr(nodename)
	
   	puts "\e[H\e[2J" #clear screen
	puts "Hostname: #{nodename} - #{ipaddr[0]}".bold.cyan
	puts 
	puts
	port = getF5port(ipaddr)
	pool = getF5pool(ipaddr)
	lb = getF5lb(pool)
	if pool.nil? || pool.empty? 
		puts "Not in F5.".yellow
		noop
	else
		puts "This system is in the F5 loadbalancers.".yellow
		pool.each do |lb,pool,port|
			puts "F5: #{lb}:#{pool}:#{port}:#{ipaddr[0]}".blue
			disableF5member(lb,pool,ipaddr[0],port,f5user,pass)
		end
	end


	################
	# Commands that are ran on each individual system
	################
	puts ""
	puts ""
	puts "Logged into #{nodename}.".magenta.underline
	puts ""
	puts ""
	puts s.cmd("String" => "sudo su", "Match" => /#{f5user}/)
	puts s.cmd("#{pass}")
	puts s.cmd("hostname -f;uname -srvm")
	puts ""
	puts "Starting Patch with: #{cmdline}"
	if reboot_server == true
		puts s.cmd("String" => "#{cmdline}", "Match" => /reboot/)
		s.close
		sleep 90
		s = Net::SSH::Telnet.new(
                	"Host" => "#{nodename}",
	               	"Username" => "#{user}",
	            	"Password" => "#{pass}"
        	)
		puts "Searching for java process(es)"
		puts s.cmd("pgrep -l java")
		if pool.nil? || pool.empty?
			puts "Waiting 10 seconds for system to stabilize before continuing.".yellow
			sleep 10
			puts
		else
			puts "Waiting 30 seconds for system to stabilize before returning to LB pool.".yellow
			sleep 30
			puts
	        pool.each do |lb,pool,port|
                puts "F5: #{lb}:#{pool}:#{port}:#{ipaddr[0]}".blue
				enableF5member(lb,pool,ipaddr[0],port,f5user,pass)
			end
		end
	else
		puts s.cmd("#{cmdline}")
		puts "Searching for java process(es)"
		puts s.cmd("pgrep -l java")
        if pool.nil? || pool.empty?
           	puts "Waiting 5 seconds for system to stabilize before continuing.".yellow
           	sleep 5
           	puts
       	else
           	puts "Waiting 5 seconds for system to stabilize before returning to LB pool.".yellow
           	sleep 5
           	puts
           	pool.each do |lb,pool,port|
	           	puts "Doing: #{lb}:#{pool}:#{port}:#{ipaddr[0]}".blue
	           	enableF5member(lb,pool,ipaddr[0],port,f5user,pass)
	        end
	    end
   	end
end
puts
puts
puts
puts
puts "Task finished..."
puts "End of Line".blink
puts
puts
puts
puts
