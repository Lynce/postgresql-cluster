require 'digest/md5'

# setup PGDG repositories and install Postgres client libraries
include_recipe 'postgresql::default'

# discovery phase
# first, populate /etc/hosts from search results
def extract_cluster_ip(node_results)
  use_interface = node['postgresql-cluster']['use_interface']
  node_results['network_interfaces'][use_interface]['addresses']
    .select { |k,v| v['family'] == 'inet' }.keys
end

found_nodes = search(:node, "name:postgresql-*",
  filter_result: {
    'name' => [ 'name' ],
    'fqdn' => [ 'fqdn' ],
    'network_interfaces' => [ 'network', 'interfaces' ]
  }
).reject { |nodedata| nodedata['network_interfaces'].nil? } #not if no interface data
  .reject { |nodedata| nodedata['name'] == node.name } # not if it's me

found_nodes.each do |nodedata|
  hostsfile_entry extract_cluster_ip(nodedata) do
    hostname nodedata['name']
    aliases [ nodedata['fqdn'], nodedata['name'].split('.').first ]
    unique true
    comment 'Chef postgresql-cluster cookbook'
  end
end

# then set pgpool data based on search results
found_nodes.each_with_index do |nodedata,index|
  node.set['pgpool']['pgconf']["backend_hostname#{index}"] = nodedata['name']
  node.set['pgpool']['pgconf']["backend_port#{index}"] = node['postgresql']['config']['port']
  node.set['pgpool']['pgconf']["backend_weight#{index}"] = 1
  node.set['pgpool']['pgconf']["backend_data_directory#{index}"] = node['postgresql']['dir']
  node.set['pgpool']['pgconf']["backend_flag#{index}"] = 'ALLOW_TO_FAILOVER'
end

# oddly if you don't install the postgres server packages, the postgres home dir gets created in a different place
user 'postgres' do
  home node['postgresql']['home']
  shell '/bin/bash'
end

# install pgpool
include_recipe 'pgpool::default'

# pgpool+repmgr failover scripts
include_recipe 'postgresql-cluster::ssh_trust'

# failover.sh runs on a pgpool node - it is supposed to ssh to the new master node to promote
template "#{node['pgpool']['config']['dir']}/failover.sh" do
  source 'failover.sh.erb'
  owner 'root'
  group 'root'
  mode 00755
end

template "#{node['pgpool']['config']['dir']}/follow_master.sh" do
  source 'follow_master.sh.erb'
  owner 'root'
  group 'root'
  mode 00755
end

# TODO: create a method to generate the pool_passwd from a list of DB usernames + passwords
# should generate "replication:md5fea8040a27d261e5ce47cacd41b48a90"
pool_passwd_content = "#{node['postgresql-cluster']['repmgr']['db_user']}:md5" + Digest::MD5::hexdigest(
  node['postgresql-cluster']['repmgr']['db_password'] + node['postgresql-cluster']['repmgr']['db_user']
) + "\n"

file "#{node['pgpool']['config']['dir']}/#{node['pgpool']['pgconf']['pool_password']}" do
  owner 'postgres'
  group 'postgres'
  mode 00640
  action :create
  content pool_passwd_content
  notifies :restart, 'service[pgpool]', :delayed
end

# same for pcp.conf but with a *slightly* different format and hashing input
pcp_content = node['postgresql-cluster']['repmgr']['db_user'] + ':' +
  Digest::MD5::hexdigest(node['postgresql-cluster']['repmgr']['db_password']) + "\n"

# TODO: patch upstream cookbook to make the pcp.conf template take inputs
file "#{node['pgpool']['config']['dir']}/pcp.conf" do
  owner 'postgres'
  group 'postgres'
  mode 00640
  action :create
  content pcp_content
  notifies :restart, 'service[pgpool]', :delayed
end

#  sysctl net.core.somaxconn - should be 256?
# http://jensd.be/591/linux/setup-a-redundant-postgresql-database-with-repmgr-and-pgpool
# http://linux.xvx.cz/2014/10/loadbalancing-of-postgresql-databases.html
# https://github.com/abessifi/pgpool-online-recovery
# http://www.pgpool.net/pgpool-web/contrib_docs/pgpool-II-3.5.pdf

# maybe install pgpooladmin?  http://git.postgresql.org/gitweb/?p=pgpooladmin.git;a=summary
