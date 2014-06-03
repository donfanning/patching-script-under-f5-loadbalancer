#!/usr/bin/ruby

require "rubygems"
require "f5-icontrol"
require "soap/wsdlDriver"
require "resolv"
require 'sqlite3'
require 'pp'

loadbalancers=["f5-lb-1.example.com", "f5-lb-2.example.com", "f5-lb-3.example.com"]
user="username"
pass="password"

db = SQLite3::Database.new "f5_partition.sqlite3"
db.execute "delete from pools"
db.execute "delete from members"
puts "Database cleaned."

loadbalancers.each do |bigipaddr|
bigip = F5::IControl.new(bigipaddr, user, pass, ["Management.Partition", "LocalLB.Pool", "LocalLB.PoolMember"]).get_interfaces

bigip["Management.Partition"].set_active_partition('MOBILE')

def valid_rdns?(ipaddr)
	begin 
	  hostname = Resolv.getname(ipaddr)
	rescue Resolv::ResolvError
          hostname = ""
        end
        return hostname
end

pools = bigip['LocalLB.Pool'].get_list.sort


pools.each do |pool|
        db.execute "insert into pools values (?)",pool
#        puts pool
end

puts "#{bigipaddr} pools imported."

#db.execute ("select * from pools") do |row|
pools.each do |row|
	poolname = row
	puts poolname
	bigip['LocalLB.Pool'].get_monitor_instance([poolname])[0].collect do |member|
		node_addr = member['instance']['instance_definition']['ipport']['address'].to_s
	  	node_port = member['instance']['instance_definition']['ipport']['port'].to_s
		#host_name = Resolv.getname(node_addr)
		host_name = valid_rdns?(node_addr)
#		puts "#{bigipaddr}:#{poolname}:#{host_name}:#{node_addr}:#{node_port}"
		stmnt1 = db.prepare ("insert into members (bigipaddr,pool,member,ipaddr,ipport) values (?,?,?,?,?)")
		stmnt1.execute(bigipaddr,poolname,host_name,node_addr,node_port)
		puts "Node: #{host_name}(#{node_addr}):#{node_port}"
	end
	bigip['LocalLB.PoolMember'].get_session_enabled_state([poolname])[0].each do |member|
		address = member['member']['address']
		port = member['member']['port']
		session_state = member['session_state']
		stmnt2 = db.prepare ("UPDATE members SET state = ? WHERE ipaddr = ? and ipport = ?")
		stmnt2.execute(session_state,address,port)
		puts "Node Status: #{session_state}"
	end

end
puts "#{bigipaddr} members imported."
end
