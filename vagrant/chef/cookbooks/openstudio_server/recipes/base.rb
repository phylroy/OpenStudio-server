#*******************************************************************************
# OpenStudio(R), Copyright (c) 2008-2016, Alliance for Sustainable Energy, LLC.
# All rights reserved.
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# (1) Redistributions of source code must retain the above copyright notice,
# this list of conditions and the following disclaimer.
#
# (2) Redistributions in binary form must reproduce the above copyright notice,
# this list of conditions and the following disclaimer in the documentation
# and/or other materials provided with the distribution.
#
# (3) Neither the name of the copyright holder nor the names of any contributors
# may be used to endorse or promote products derived from this software without
# specific prior written permission from the respective party.
#
# (4) Other than as required in clauses (1) and (2), distributions in any form
# of modifications or other derivative works may not use the "OpenStudio"
# trademark, "OS", "os", or any other confusingly similar designation without
# specific prior written permission from Alliance for Sustainable Energy, LLC.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER, THE UNITED STATES
# GOVERNMENT, OR ANY CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
# LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
# LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
# EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#*******************************************************************************

#
# Cookbook Name:: openstudio_server
# Recipe:: base
#
# Recipe installs the base software needed for openstudio analysis (both server and worker)

# Eventually remove the roles tab and use this for configuring the system.

# General useful utilities
# include_recipe 'apt'
# include_recipe 'ntp'
# include_recipe 'cron'
# include_recipe 'man'
# include_recipe 'vim'

# A much nicer replacement for grep.
# include_recipe 'ack'

# Zip/Unzip
# include_recipe 'zip'

# Sudo - careful installing this as you can easily prevent yourself from using sudo
node.default['authorization']['sudo']['users'] = %w(vagrant ubuntu)
# set the sudoers files so that it has access to rbenv
secure_path = "#{node[:rbenv][:root_path]}/shims:#{node[:rbenv][:root_path]}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
node.default['authorization']['sudo']['sudoers_defaults'] = [
  'env_reset',
  "secure_path=\"#{secure_path}\""
]
node.default['authorization']['sudo']['passwordless'] = true
node.default['authorization']['sudo']['include_sudoers_d'] = true
node.default['authorization']['sudo']['agent_forwarding'] = true
include_recipe 'sudo'

node.override['logrotate']['global']['rotate'] = 30
node.override['logrotate']['global']['compress'] = true
%w(monthly weekly yearly).each do |freq|
  node.override['logrotate']['global'][freq] = false
end
node.override['logrotate']['global']['daily'] = true
include_recipe 'logrotate::global'

# logrotate_app 'tomcat-myapp' do
#   cookbook  'logrotate'
#   path      '/var/log/tomcat/myapp.log'
#   options   ['missingok', 'delaycompress']
#   frequency 'daily'
#   rotate    30
#   create    '644 root adm'
# end

include_recipe 'rbenv'
include_recipe 'rbenv::ruby_build'

# Install rbenv and Ruby

# Set env variables as they are needed for openstudio linking to ruby
ENV['RUBY_CONFIGURE_OPTS'] = '--enable-shared'
ENV['CONFIGURE_OPTS'] = '--disable-install-doc'

rbenv_ruby node[:openstudio_server][:ruby][:version] do
  global true
end

# Add any gems that require compilation here otherwise the workflow gem won't be able to use them
%w(bundler libxml-ruby ruby-prof).each do |g|
  rbenv_gem g do
    ruby_version node[:openstudio_server][:ruby][:version]
  end
end

# Add user to rbenv group
Chef::Log.info "Adding user '#{node[:openstudio_server][:bash_profile_user]}' to '#{node[:rbenv][:group]}' group"
group node[:rbenv][:group] do
  action :modify
  members node[:openstudio_server][:bash_profile_user]
  append true
end

# set the passenger node values to the location of rbenv - languages is not accessible
# Chef::Log.info "Resetting passenger root path to #{languages['ruby']['gems_dir']}/gems/passenger-#{node['passenger']['version']}"
# Chef::Log.info "Resetting passenger ruby bin path to #{languages['ruby']['ruby_bin']}"

Chef::Log.info 'Resetting the root_path and ruby_bin for Passenger'
node.override['passenger']['root_path'] = "/opt/rbenv/versions/#{node[:openstudio_server][:ruby][:version]}/lib/ruby/gems/2.0.0/gems/passenger-#{node['passenger']['version']}"
node.override['passenger']['ruby_bin'] = "/opt/rbenv/versions/#{node[:openstudio_server][:ruby][:version]}/bin/ruby"

# add an environment variable to the system so that we know we are running in OpenStudio Server mode
template '/etc/profile.d/openstudio_server.sh' do
  source 'openstudio_server.sh.erb'
  mode '0775'
  owner 'root'
  group 'root'
end
