deploy_rails
============

Use Shell script to update rails applications on remote servers through git, and execute bundle install, rake db:migration, asset precompile and restart unicorn...

I tried to use Capistrano to do the deployment, but met a lot of problems, such as configuration, ruby version, code upgrade...then I decided to write my own script to do the job.

## Prerequirements

You need to follow following steps to deploy you ruby on rails application to a Ubuntu + Nginx + Unicorn environment. Here I installed RVM as multiple users mode. And I use `www-data` user to run my app.

If you are using different OS, you may need adjust some configurations in following steps accordingly.

### 0\. Deploy source code

As root, change user `www-data`'s shell to bash and set its home folder to `/var/www`

#### # vi /etc/passwd
```
www-data:x:33:33:www-data:/var/www:/bin/sh
==>
www-data:x:33:33:www-data:/var/www:/bin/bash
```

To checkout source code from git server, you need to create ssh key for `www-data` and add the public key string to your git server (github or private gitlab)
```
sudo su - www-data
$ ssh-keygen ###(Here don't input any password)
$ cat /var/www/.ssh/id_rsa.pub
......
```

On your production server, check out your application code from git server.

```
sudo su - www-data
$ git clone https://github.com/MYNAME/MYAPP.git

```


### 1\. Change configuration of the application for "production" environment:

#### config/database.yml
```
production:
adapter: mysql2
encoding: utf8
reconnect: false
database: MyApp
pool: 5
username: root
password: password
socket: /var/run/mysqld/mysqld.sock
host: 192.168.1.61
```

#### config/environments/production.rb
```
# Disable Rails’s static asset server (Apache or nginx will already do this)
config.serve_static_assets = true
```

### 2\. Setup RVM for multi-users
I use this mode because I want user `www-data` can use rvm directly 
```
$ \curl -L https://get.rvm.io | sudo bash -s stable
```

### 3\. Setup Ruby by RVM

```
$ rvmsudo rvm get head
$ rvmsudo -s rvm pkg install openssl
$ sudo su -

###(The following changes only for China mainland, because it is very slow to connect https://rubygems.org/)

# gem sources –remove https://rubygems.org/

# gem sources -a http://ruby.taobao.org/

# gem sources -l

*** CURRENT SOURCES ***
http://ruby.taobao.org
### ensure only ruby.taobao.org

# sed -i ‘s!ftp.ruby-lang.org/pub/ruby!ruby.taobao.org/mirrors/ruby!’$rvm_path/config/db

# exit

$ rvmsudo -s rvm install 2.0.0
```

Open `/etc/bash.bashrc` or `/etc/bashrc` (whichever is available) and add the following to the end of the file. Also run this command in your terminal.
```
export PATH=$PATH:/usr/local/rvm/gems/ruby-2.0.0-p247/bin
export RAILS_ENV=production
source /etc/profile.d/rvm.sh
rvm use 2.0.0 >/dev/null 2>/dev/null
```

Open /var/www/.bashrc and add following:
```
source /etc/profile.d/rvm.sh
rvm use 2.0.0 >/dev/null 2>/dev/null
```
 
### 4\. Setup Unicorn as root
```
$ sudo su -
# gem install bundler
# gem install unicorn
```
or `gem install –verbose –debug unicorn` (with detailed information)

if got exception like:
    
```
Exception `OpenSSL::SSL::SSLError’ at /usr/local/rvm/rubies/ruby-2.0.0-p247/lib/ruby/2.0.0/openssl/buffering.rb:174 – read would block
```

Edit .gemrc :    
```
–-
:ssl_verify_mode: 0
:backtrace: false
:benchmark: false
:bulk_threshold: 1000
:sources:
- http://ruby.taobao.org/
:update_sources: true
:verbose: true
```

### 5\. Setup some required libs (for my app):
```
# apt-get install libmysqlclient-dev imagemagick libmagickwand-dev
```

### 6\. Install bundlers as root

First, add following to Gemfile of the application:
```
gem 'unicorn'
gem 'unicorn-worker-killer'
```

Then execute following commands:
```
# bundle update rails
# bundle install
```

### 7\. Configure Unicorn to be executed by www-data

#### $ vi config/unicorn.rb

```
# config/unicorn.rb
# Set environment to development unless something else is specified
env = ENV["RAILS_ENV"] || "development"

# See http://unicorn.bogomips.org/Unicorn/Configurator.html for complete
# documentation.
worker_processes 6

app_root = File.expand_path("../..", __FILE__)
working_directory app_root

# listen on both a Unix domain socket and a TCP port,
# we use a shorter backlog for quicker failover when busy
listen "/tmp/unicorn.socket", :backlog => 64
listen 4096, :tcp_nopush => false

# Preload our app for more speed
preload_app true
GC.respond_to?(:copy_on_write_friendly=) and
  GC.copy_on_write_friendly = true

# nuke workers after 300 seconds instead of 60 seconds (the default)
timeout 300

pid "#{app_root}/tmp/pids/unicorn.pid"

# Production specific settings
if env == "production"
  # Help ensure your application will always spawn in the symlinked
  # "current" directory that Capistrano sets up.
  working_directory app_root

  # feel free to point this anywhere accessible on the filesystem
  user 'www-data', 'www-data'

  stderr_path "#{app_root}/log/unicorn.stderr.log"
  stdout_path "#{app_root}/log/unicorn.stdout.log"
end

# Force the bundler gemfile environment variable to
# reference the Сapistrano "current" symlink
before_exec do |_|
  ENV["BUNDLE_GEMFILE"] = File.join(app_root, 'Gemfile')
end

before_fork do |server, worker|
  # the following is highly recomended for Rails + "preload_app true"
  # as there's no need for the master process to hold a connection
  if defined?(ActiveRecord::Base)
    ActiveRecord::Base.connection.disconnect!
  end

  # Before forking, kill the master process that belongs to the .oldbin PID.
  # This enables 0 downtime deploys.
  old_pid = app_root + '/tmp/pids/unicorn.pid.oldbin'
  if File.exists?(old_pid) && server.pid != old_pid
    begin
      Process.kill("QUIT", File.read(old_pid).to_i)
    rescue Errno::ENOENT, Errno::ESRCH
      # someone else did our job for us
    end
  end
end

after_fork do |server, worker|
  # Disable GC, together with the OOB after to reduce the execution time
  GC.disable
  # the following is *required* for Rails + "preload_app true",
  if defined?(ActiveRecord::Base)
    ActiveRecord::Base.establish_connection
  end

  # if preload_app is true, then you may also want to check and
  # restart any other shared sockets/descriptors such as Memcached,
  # and Redis.  TokyoCabinet file handles are safe to reuse
  # between any number of forked children (assuming your kernel
  # correctly implements pread()/pwrite() system calls)
end

```

#### $ vi config.ru    
```
# This file is used by Rack-based servers to start the application.

require ‘unicorn/oob_gc’
require ‘unicorn/worker_killer’

# execute 1 GC every 10 requests
use Unicorn::OobGC, 10

# Set the max request time to avoid mem leak by GC (random from 3072 to 4096 so the processes will not kill themselves at the same time)
use Unicorn::WorkerKiller::MaxRequests, 3072, 4096

# Set the max memery size to avoid mem leak by GC (random from 192 to 256 MB so the processes will not kill themselves at the same time)
use Unicorn::WorkerKiller::Oom, (192*(1024**2)), (256*(1024**2))

require ::File.expand_path(‘../config/environment’,??__FILE__)
run MyApp::Application
```

### 8\. Configure Nginx

#### # vi /etc/nginx/sites-enabled/default    
```
upstream myapp {
	# fail_timeout=0 means we always retry an upstream even if it failed
	# to return a good HTTP response (in case the Unicorn master nukes a
	# single worker for timing out).
	# for UNIX domain socket setups:
	server unix:/tmp/unicorn.socket fail_timeout=0;
}

server {
	listen   80; ## listen for ipv4; this line is default and implied
	#listen   [::]:80 default_server ipv6only=on; ## listen for ipv6

	root /var/www/MYAPP/public;
	index index.html index.htm;

	# Make site accessible
	server_name myhostname.com;

	location / {
		proxy_pass  http://myapp;
		proxy_redirect     off;

		proxy_set_header   Host             $host;
		proxy_set_header   X-Real-IP        $remote_addr;
		proxy_set_header   X-Forwarded-For  $proxy_add_x_forwarded_for;

		client_max_body_size       10m;
		client_body_buffer_size    128k;

		proxy_connect_timeout      90;
		proxy_send_timeout         90;
		proxy_read_timeout         90;

		proxy_buffer_size          4k;
		proxy_buffers              4 32k;
		proxy_busy_buffers_size    64k;
		proxy_temp_file_write_size 64k;

	}

	location ~ ^/(assets)/{
		root /var/www/MYAPP/public;
		expires max;
		add_header Cache-Control public;
	}

	location ~* \.(jpg|jpeg|gif|png|ico|css|bmp|js|html)$ {
		root   /var/www/MYAPP/public;
	}
}
```

	
## Deploy the script

### 1\. Copy [unicorn](https://github.com/tangramor/deploy_rails/blob/master/unicorn) scritp to `/etc/init.d/unicorn` and make it executable

```
chmod +x /etc/init.d/unicorn
```

### 2\. Edit `/etc/init.d/unicorn` to match your environment

```
USER="www-data"
DAEMON=unicorn
RUBY_VERSION=2.0.0
RAILS_ENV=production
RVM_PROFILE="/etc/profile.d/rvm.sh"
APPPATH="/var/www/MYAPP"
DAEMON_OPTS="-c $APPPATH/config/unicorn.rb -E $RAILS_ENV -D"
NAME=unicorn
DESC="Unicorn app for $USER"
PID=$APPPATH/tmp/pids/unicorn.pid
```

In most cases, you just need to modify `USER`, `RUBY_VERSION`, `RAILS_ENV`, `RVM_PROFILE` and `APPPATH` to the values of your server

### 3\. Set unicorn auto start when boot up
```
# update-rc.d unicorn defaults
```

### 4\. Configure SSH connection between workstation and servers
You need to generate ssh key on your workstation. For example, my work machine is a laptop and I installed Ubuntu 13.10 on it, so I generate ssh key by execute `ssh-keygen` without input passphrase for the key (this will generate a key with no passphrase)
```
$ ssh-keygen
Generating public/private rsa key pair.
Enter file in which to save the key (/home/USERNAME/.ssh/id_rsa):
......
```
Then append the public key string to the servers. In this case we use `www-data` user, so just log in the server, open `/var/www/.ssh/authorized_keys` and add the content of `/home/USERNAME/.ssh/id_rsa.pub` on you workstation to it:

```
On your workstation------------------------------------------
$ scp ~/.ssh/id_rsa.pub ServerUser@192.168.1.61:~/id_rsa.pub
$ ssh ServerUser@192.168.1.61

Now we are on 192.168.1.61-----------------------------------
$ cat ~/id_rsa.pub | sudo -u www-data sh -c "cat - >>/var/www/.ssh/authorized_keys"
$ rm ~/id_rsa.pub
```

### 5\. Deploy code changes
After you committed any change on you app and pushed to your git server, you can execute [update_unicorn.sh](https://github.com/tangramor/deploy_rails/blob/master/update_unicorn.sh) to deploy the changes to your production servers. You need to edit `update_unicorn.sh` to match your environment
```
SERVER_IPS=(192.168.1.61 192.168.1.62)
SERVER_USERS=(www-data www-data)
RUBY_VERSION=2.0.0
RVM_PROFILE="/etc/profile.d/rvm.sh"
```
In this example we have 2 servers: 192.168.1.61 and 192.168.1.62. And on both server we use `www-data` user to execute the rails application.

### Reference:

1. http://ihower.tw/rails3/deployment.html

2. http://ruby-china.org/topics/12033

3. http://ruby.taobao.org/

4. http://ariejan.net/2011/09/14/lighting-fast-zero-downtime-deployments-with-git-capistrano-nginx-and-unicorn/
