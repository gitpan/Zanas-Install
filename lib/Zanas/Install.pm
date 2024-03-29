package Zanas::Install;

package main;

use Term::ReadLine;
use Term::ReadPassword;
use File::Find;
use DBI;
use Data::Dumper;
use Fcntl qw(:DEFAULT :flock);
use File::Temp qw(tempfile);
use Text::Iconv;
use Carp;

################################################################################

sub _cd {

	$ARGV [0] =~ /^\[[\w\-]+\]$/ or return;
	
	my $appname = shift (@ARGV);
	
	$appname =~ s{\[}{};
	$appname =~ s{\]}{};
	
	my $httpd = _local_exec ("which apache; which httpd");
	
	my $config_file_option =  _local_exec ("apache -V | grep SERVER_CONFIG_FILE");
	
	$config_file_option =~ /\=\"(.*?)\"/;
	
	my $config_file = $1;
	
	my $include_line = _local_exec ("cat /etc/apache/httpd.conf | grep $appname/conf/httpd.conf");
	
	$include_line = (split /\n/, $include_line) [0];
	$include_line =~ s{Include}{};
	$include_line =~ s{conf/httpd.conf}{};
	$include_line =~ s{\"}{}g;
	$include_line =~ s{\s}{}g;
	
	chdir $include_line;

	_local_exec ("pwd");

}

################################################################################

sub _local_exec {

	my $line = $_[0];	
	$line =~ s{\-p\".*?\"}{-p********}g;

	print STDERR " {$line";

	my $time = time;
	my $stdout = `$_[0]`;
	my $timing = ', ' . (time - $time) . ' s elapsed.';
	
	if ($_[0] !~ /cat / && $stdout =~ /./) {
		$stdout =~ s{^}{  }gsm;
		print STDERR "\n$stdout }$timing\n";
	}
	else {
		print STDERR "}$timing\n";
	}

	return $stdout;
	
}

################################################################################

sub _master_exec {

	my ($preconf, $cmd) = @_;
	
	my $ms = $preconf -> {master_server};
	
	_local_exec (
		$ms -> {host} eq 'localhost' ? 
			$cmd : 
			"ssh -l$$ms{user} $$ms{host} '$cmd'"
	)
	
}

################################################################################

sub restore_local_libs {
	my ($path) = @_;
	$path ||= $ARGV [0];
	_log ("Unpacking $path...");
	_local_exec ("tar xzfm $path");
	_local_exec ("chmod -R a+rwx lib/*");
}

################################################################################

sub restore_local_i {

	my ($path) = @_;
	$path ||= $ARGV [0];

	my $local_preconf = _read_local_preconf ();

#	_log ("Removing i...");
#	_local_exec ("rm -rf docroot/i/*");
	_log ("Unpacking $path...");
	_local_exec ("tar xzfm $path");
	_local_exec ("chmod -R a+rwx docroot/i/*");
	
}

################################################################################

sub restore_local_db {

	my ($path) = @_;	
	$path ||= $ARGV [0];

	my $local_preconf = _read_local_preconf ();
	
	_log ("Unzipping $path...");
	_local_exec ("gunzip $path");
	$path =~ s{\.gz$}{};
	
	_log ("Feeding $path to MySQL...");
	_local_exec ("mysql -u$$local_preconf{db_user} -p\"$$local_preconf{db_password}\" $$local_preconf{db_name} < $path");

	_log ("DB restore complete.");
	
}

################################################################################

sub restore {
	restore_local (@_);
}

################################################################################

sub restore_local {

	my ($time, $skip_libs) = @_;
	$time ||= $ARGV [0];	
	$time ||= readlink 'snapshots/latest.tar.gz';

	$time =~ s{snapshots\/}{};
	$time =~ s{\.tar\.gz}{};
	
	backup_local ();

	my $path = "snapshots/$time.tar.gz";
	-f $path or die "File not found: $path\n";
	_log ("Restoring $path on local server...");
	_log ("Unpacking $path...");
	_local_exec ("tar xzfm $path");

	$time =~ s{master_}{};

	my $local_preconf = _read_local_preconf ();
	my $local_conf    = _read_local_conf    ();
	
	unless ($skip_libs) {
		my $lib_path = 'lib/' . $local_conf -> {application_name} . '.' . $time . '.tar.gz';
		restore_local_libs ($lib_path);
		_log ("Removing $lib_path...");
		_local_exec ("rm $lib_path");
	}
	
	if ($local_preconf -> {master_server} -> {static} eq 'none') {
		_log ("RESTORING STATIC FILES ON LOCAL SERVER IS SKIPPED.");
	}
	elsif ($local_preconf -> {master_server} -> {static} eq 'rsync') {
		my $s = $local_preconf -> {master_server};
		_log ("Synchronizing static files...");
		_local_exec ("rsync -r -essh $$s{user}\@$$s{host}:$$s{path}/docroot/i/* docroot/i/");
	} 
	else {
		my $i_path = 'docroot/i.' . $time . '.tar.gz';
		restore_local_i ($i_path);
		_log ("Removing $i_path...");
		_local_exec ("rm $i_path");
	}

	my $db_path = 'sql/' . $local_preconf -> {db_name} . '.' . $time . '.sql.gz';
	restore_local_db ($db_path);
	$db_path =~ s{\.gz$}{};
	_log ("Removing $db_path...");
	_local_exec ("rm $db_path");
	
}

################################################################################

sub timestamp {

	$time ||= time;

	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday) = gmtime ($time);
	$mon ++;
	$year += 1900;

	return sprintf ("%4d-%02d-%02d-%02d-%02d-%02d", $year, $mon, $mday, $hour, $min, $sec);

}

################################################################################

sub _db_path {
	my ($db_name, $time) = @_;
	$time ||= time;
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday) = gmtime ($time);
	$mon ++;
	$year += 1900;
	return "sql/$db_name." . timestamp () . ".sql";
}

################################################################################

sub _lib_path {
	my ($application_name, $time) = @_;
	$time ||= time;
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday) = gmtime ($time);
	$mon ++;
	$year += 1900;
	return "lib/$application_name." . timestamp () . ".tar.gz";
}

################################################################################

sub _i_path {
	my ($time) = @_;
	$time ||= time;
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday) = gmtime ($time);
	$mon ++;
	$year += 1900;
	return "docroot/i." . timestamp () . ".tar.gz";
}

################################################################################

sub _snapshot_path {
	my ($time) = @_;
	$time ||= time;
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday) = gmtime ($time);
	$mon ++;
	$year += 1900;
	return "snapshots/" . timestamp () . ".tar.gz";
}

################################################################################

sub backup {
	backup_local (@_);
}




################################################################################

sub cleanup {

	_log ("Cleaning up logs...");
	_local_exec ("find -path '*/logs/*' -exec rm {} \\;");

	_log ("Cleaning up snapshots...");
	_local_exec ("find -path '*/snapshots/*' -exec rm {} \\;");

}

################################################################################

sub backup_local {

	my ($time) = @_;
	$time ||= time;
	_log ("Backing up application on local server...");
	my $db_path   = backup_local_db   ($time);
	my $libs_path = backup_local_libs ($time);
	my $i_path    = backup_local_i    ($time);
	my $path      = _snapshot_path    ($time);
	my $ln_path   = $path;
	$ln_path =~ s{^snapshots/}{};
	
	_log ("Creating $path...");
	_local_exec ("tar czf $path $db_path $libs_path $i_path");

	_log ("Creating symlink snapshots/latest.tar.gz...");
	_local_exec ("rm snapshots/latest.tar.gz*");
	_local_exec ("ln -s $ln_path snapshots/latest.tar.gz");
	
	_log ("Removing $db_path...");
	_local_exec ("rm $db_path");
	
	_log ("Removing $libs_path...");
	_local_exec ("rm $libs_path");
	
	if ($i_path) {
		_log ("Removing $i_path...");
		_local_exec ("rm $i_path");
	}

	_log ("Backup complete");
	return $path;
	
}

################################################################################

sub sync_down {

	my $time = time;

	my $snapshot_path = backup_master ();
	
	my $local_preconf = _read_local_preconf ();
	my $local_conf = _read_local_conf ();		

	_log ("Copying $snapshot_path from master...");
	_cp_from_master ($local_preconf, $local_preconf -> {master_server} -> {path} . '/' . $snapshot_path, 'snapshots/');
	
	restore_local ($snapshot_path, $local_preconf -> {master_server} -> {skip_libs});

	my $timing = ', ' . (time - $time) . ' s elapsed.';

	_log ("Sync complete$timing\n");

}

################################################################################

sub _log {

	print "$_[0]\n";

}

################################################################################

sub sync_up {
		
	my $libs_path = backup_local_libs ();

	my $local_preconf = _read_local_preconf ();
	my $local_conf = _read_local_conf ();		

	my $master_path = $local_preconf -> {master_server} -> {path};

	my $master_libs_path = backup_master_libs ();
	$master_libs_path =~ s{$master_path\/}{};	

	_log ("Removing $master_libs_path...");
	_master_exec ($local_preconf, "cd $master_path; rm $master_libs_path");

	_log ("Copying $libs_path to master...");
	_cp_to_master ($local_preconf, $libs_path, $local_preconf -> {master_server} -> {path} . '/' . $libs_path);

	_log ("Removing $libs on master...");
	_master_exec ($local_preconf, "cd $master_path; rm -rf libs/*");

	_log ("Unpacking $libs on master...");
	_master_exec ($local_preconf, "cd $master_path; tar xzfm $libs_path");

	_log ("Removing $libs_path on master...");
	_master_exec ($local_preconf, "cd $master_path; rm $libs_path");

	_log ("Removing $libs_path locally...");
	_local_exec ("rm $libs_path");

	_log ("Sync complete");
	
}

################################################################################

sub _cp_from_master {

	my ($conf, $from, $to) = @_;
	my $ms = $conf -> {master_server};
	
	my $ex = $ms -> {host} eq 'localhost' ? 
		"cp $from $to": 	
		"scp $$ms{user}\@$$ms{host}:$from $to";

	_local_exec ($ex);

}

################################################################################

sub _cp_to_master {

	my ($conf, $from, $to) = @_;
	my $ms = $conf -> {master_server};
	
	my $ex = $ms -> {host} eq 'localhost' ? 
		"cp $from $to": 	
		"scp $from $$ms{user}\@$$ms{host}:$to";
		
	_local_exec ($ex);

}

################################################################################

sub backup_master {

	my ($time) = @_;
	$time ||= time;
	_log ("Backing up application on master server...");
	
	my $local_preconf = _read_local_preconf ();	
	my $local_conf = _read_local_conf ();	
	
	my $master_preconf = _read_master_preconf ();
	my $master_path = $local_preconf -> {master_server} -> {path};
	
	my $db_path = backup_master_db ($time);
	$db_path =~ s{$master_path\/}{};
	
	my $libs_path = '';
	unless ($local_preconf -> {master_server} -> {skip_libs}) {
		$libs_path = backup_master_libs ($time);
		$libs_path =~ s{$master_path\/}{};	
	}	
	
	my $i_path = backup_master_i ($time);
	$i_path =~ s{$master_path\/}{};	

	my $path = _snapshot_path ($time);
	$path =~ s{snapshots\/}{snapshots\/master_};
	
	_log ("Creating $path...");
	_master_exec ($local_preconf, "cd $master_path; tar czf $master_path/$path $db_path $libs_path $i_path");
	
	_log ("Removing $db_path...");
	_master_exec ($local_preconf, "cd $master_path; rm $db_path");
	
	unless ($local_preconf -> {master_server} -> {skip_libs}) {
		_log ("Removing $libs_path...");
		_master_exec ($local_preconf, "cd $master_path; rm $libs_path");
	}
	
	if ($i_path) {
		_log ("Removing $i_path...");
		_master_exec ($local_preconf, "cd $master_path; rm $i_path");
	}
	
	_log ("Backup complete");
	
	return $path;
	
}

################################################################################

sub backup_local_db {

	my ($time) = @_;
	$time ||= time;
	my $local_preconf = _read_local_preconf ();	
	my $path = _db_path ($local_preconf -> {db_name}, $time);
	_log ("Backing up db $$local_preconf{db_name} on local server...");
	
	_local_exec ("mysqldump --add-drop-table -Keq -u$$local_preconf{db_user} -p\"$$local_preconf{db_password}\" $$local_preconf{db_name} | gzip > $path.gz");
		
	_log ("DB backup complete");
	return "$path.gz";
		
}

################################################################################

sub backup_master_db {

	my ($time) = @_;
	$time ||= time;	

	my $local_preconf = _read_local_preconf ();	
	my $local_conf = _read_local_conf ();	

	my $master_preconf = _read_master_preconf ();	
	my $path = $local_preconf -> {master_server} -> {path} . '/' . _db_path ($local_preconf -> {db_name}, $time);
	_log ("Backing up db $$master_preconf{db_name} on master server...");
	
	_log ("Listing tables...");	
	my $tables = _master_exec ($local_preconf, "mysql -u$$master_preconf{db_user} -p\"$$master_preconf{db_password}\" $$master_preconf{db_name} -se\"show tables\"");
	
	my %skip_tables = map {$_ => 1} @{$local_preconf -> {master_server} -> {skip_tables}};
			
	my @tables = split /\n/, $tables;
	
	map {s{\s}{}gsm} @tables;
	
	my $dump_cmd = '';
	
	foreach my $table (@tables) {
			
		my $opt = '-Keq';
		$opt .= 'd' if $skip_tables {$table};
				
		$dump_cmd .= "mysqldump $opt --add-drop-table -u$$master_preconf{db_user} -p\"$$master_preconf{db_password}\" $$master_preconf{db_name} $table >> $path; ";
			
	}
	
	_log ("Dumping database...");
	_master_exec ($local_preconf, $dump_cmd);
					
	_log ("Gzipping $path...");
	_master_exec ($local_preconf, "gzip $path");
	
	_log ("DB backup complete");
	return "$path.gz";
		
}

################################################################################

sub backup_local_libs {

	my ($time) = @_;
	$time ||= time;

	my $local_preconf = _read_local_preconf ();	
	my $local_conf = _read_local_conf ();

	my $path = _lib_path ($local_conf -> {application_name}, $time);

	_log ("Backing up libs on local server...");
	_local_exec ("tar czf $path lib/*");

	_log ("Lib backup complete");
	return $path;
		
}

################################################################################

sub backup_local_i {

	my ($time) = @_;
	$time ||= time;

	my $local_preconf = _read_local_preconf ();
	my $local_conf = _read_local_conf ();
		
	if ($preconf -> {master_server} -> {static} eq 'none' or $preconf -> {master_server} -> {static} eq 'rsync') {
		_log ("BACKING UP STATIC FILES ON LOCAL SERVER IS SKIPPED.");
		return '';
	}

	my $path = _i_path ($time);

	_log ("Backing up static files on local server...");
	_local_exec ("tar czf $path docroot/i/*");

	_log ("I backup complete");
	return $path;
		
}

################################################################################

sub backup_master_libs {

	my ($time) = @_;
	$time ||= time;

	my $local_preconf = _read_local_preconf ();
	my $local_conf = _read_local_conf ();

	my $master_conf = _read_master_conf ();

	my $path = $local_preconf -> {master_server} -> {path} . '/' . _lib_path ($local_conf -> {application_name}, $time);

	_log ("Backing up libs on master server...");
	_master_exec ($local_preconf, 'cd ' . $local_preconf -> {master_server} -> {path} . "; tar czf $path lib/*");
	_master_exec ($local_preconf, 'cd ' . $local_preconf -> {master_server} -> {path} . "; cp $path snapshots/latest-libs.tar.gz");

	_log ("Lib backup complete");
	return $path;
		
}

################################################################################

sub backup_master_i {

	my ($time) = @_;
	$time ||= time;

	my $local_preconf = _read_local_preconf ();
	my $local_conf = _read_local_conf ();

	if ($local_preconf -> {master_server} -> {static} eq 'none' or $local_preconf -> {master_server} -> {static} eq 'rsync') {
		_log ("BACKING UP STATIC FILES ON MASTER SERVER IS SKIPPED.");
		return '';
	}

	my $master_conf = _read_master_conf ();

	my $path = $local_preconf -> {master_server} -> {path} . '/' . _i_path ($time);

	_log ("Backing up i on master server...");
	_master_exec ($local_preconf, 'cd ' . $local_preconf -> {master_server} -> {path} . "; tar czf $path docroot/i/*");

	_log ("I backup complete");
	return $path;
		
}

################################################################################

sub restore_master_libs {

	my ($time) = @_;
	$time ||= time;

	my $local_preconf = _read_local_preconf ();
	my $local_conf = _read_local_conf ();

	_log ("Deleting libs on master server...");
	_master_exec ($local_preconf, 'cd ' . $local_preconf -> {master_server} -> {path} . "; rm -rf libs/*");

	_log ("Restoring libs on master server...");
	_master_exec ($local_preconf, 'cd ' . $local_preconf -> {master_server} -> {path} . "; tar xzfm snapshots/latest-libs.tar.gz");

	_log ("Lib restore complete");
	return $path;
		
}

################################################################################

sub _read_master_conf {

	unless ($MASTER_CONF) {

		my $local_preconf = _read_local_preconf ();
		my $local_conf = _read_local_conf ();

		my $src = _master_exec ($local_preconf, 'cat ' . $local_preconf -> {master_server} -> {path} . "/lib/$$conf{application_name}/Config.pm");
		undef $conf;
		eval $src;
		$MASTER_CONF = $conf;
		
	}

	return $MASTER_CONF;

}

################################################################################

sub _read_master_preconf {

	unless ($MASTER_PRECONF) {

		my $local_preconf = _read_local_preconf ();
		my $local_conf = _read_local_conf ();

		my $src = _master_exec ($local_preconf, 'cat ' . $local_preconf -> {master_server} -> {path} . "/conf/httpd.conf");
		$MASTER_PRECONF = _decrypt_preconf ($src);

	}

	return $MASTER_PRECONF;
	
}

################################################################################

sub _read_local_preconf {

	unless ($LOCAL_PRECONF) {
	
		_cd ();

		-f 'conf/httpd.conf' or die "ERROR: httpd.conf not found. Please, first chdir to the webapp directory.\n";
		my $src = `cat conf/httpd.conf`;
		$LOCAL_PRECONF = _decrypt_preconf ($src);
		
	}

	return $LOCAL_PRECONF;
	
}

################################################################################

sub _read_local_conf {
	
	unless ($LOCAL_CONF) {

		_cd ();

		opendir (DIR, 'lib') || die "can't opendir lib: $!";
		my ($appname) = grep {(-d "lib/$_") && ($_ !~ /\./) } readdir (DIR);
		closedir DIR;
		do "lib/$appname/Config.pm";
		$conf -> {application_name} = $appname;
		
		$LOCAL_CONF = $conf;

	}
	
	return $LOCAL_CONF;
	
}

################################################################################

sub _decrypt_preconf {
	my ($src) = @_;

#print STDERR "\$src = $src\n";

	my $preconf_src = '';

	if ($src =~ /\$preconf.*?\;/gsm) {
		$preconf_src = $&;
	}
	else {
		$src =~ /use Zanas\:\:Loader[^\{]*(\{.*\})/gsm;
		$preconf_src = $1; 
		$preconf_src or die "ERROR: can't parse httpd.conf.\n";
		$preconf_src = "\$preconf = $preconf_src";
	}
	
#print STDERR "\$preconf_src = $preconf_src\n";
	
	eval $preconf_src;
		
	$preconf -> {db_dsn}  =~ /database=(\w+)/ or die "Wrong \$preconf_src: $preconf_src\n";
	$preconf -> {db_name} = $1;
	
	if ($preconf -> {master_server}) {
		$preconf -> {master_server} -> {static} ||= 'tgz';
	}	
	
	return $preconf;
	
}

################################################################################
sub _require_svn {
    eval 'require SVN::Client;';
    if ($@) {
	die "SVN::Client not found. You should install perl binding from http://subversion.tigris.org/. Debian Linux users should install libsvn-core-perl package\n";
    }
}

################################################################################

sub create {

	my $path = $INC{'Zanas/Install.pm'};
	
	$path =~ s{Install\.pm}{static/sample.tar.gz.pm};
	
	our $term = new Term::ReadLine 'Zanas application installation';
	
	my ($appname, $appname_uc, $instpath, $db, $user, $password, $group, $admin_user, $admin_password, $dbh);
	
	my ($svn_ctx, $svn_server, $application_src, $application_dst, $appname_src, $appname_src_uc);
	our ($is_svn_error, $svn_error_str);

	while (1) {
		while (1) {
			$appname = $term -> readline ('Application name (lowercase): ');
			last if $appname =~ /[a-z_]+/
		}

		$appname_uc = uc $appname;	

		while (1) {
			my $default_instpath = $^O eq 'MSWin32' ? "G:\\do_work\\$appname" : "/var/projects/$appname";
			$instpath = $term -> readline ("Installation path [$default_instpath]: ");
			$instpath = $default_instpath if $instpath eq '';
			if (-d $instpath) {
				print "Installation path exists.\n";
				next;
			}

			last if $instpath =~ /[\w\/]+/
		}

		while ($^O ne 'MSWin32') {
			$group = $term -> readline ("Users group [nogroup]: ");
			$group = "nogroup" if $group eq '';
			last if $group =~ /\w+/
		}

		
		while (1) {
			$db = $term -> readline ("Database name [$appname]: ");
			$db = $appname if $db eq '';
			last if $db =~ /\w+/
		}

		while (1) {
			$user = $term -> readline ("Database user [$appname]: ");
			$user = $appname if $user eq '';
			last if $user =~ /\w+/
		}

		while (1) {
		
			$admin_user = $term -> readline ("Database admin user (to CREATE DATABASE only) [$ENV{USER}]: ");
			$admin_user = $$ENV{USER} if $admin_user eq '';
			$admin_password = read_password ("\nDatabase admin password (to CREATE DATABASE only): ");
			$dbh = DBI -> connect ('DBI:mysql:mysql', $admin_user, $admin_password);
			last if $dbh && $dbh -> ping ();			
			print "Can't connect to mysql database. Try again\n";
		}

		$dbh -> {RaiseError} = 1;

		print "\nApplication source\n\tpub_sample - from Zanas::Install package\n\tsvn://svn.zanas.ru/pub_sample - public web site template from svn\n\tsvn://svn.zanas.ru/sample - web application template from svn (stripped public web site template)\n\tsvn://.... - your own source\n";
		while (1) {
			$application_src = $term -> readline ('[svn://svn.zanas.ru/pub_sample]: ');
			$application_src = 'svn://svn.zanas.ru/pub_sample' unless $application_src;
			if ($application_src eq 'pub_sample') {
				last;
			} else {
				_require_svn ();

				$SVN::Error::handler = \&svn_error_handler;
				$svn_ctx = new SVN::Client(
					auth => [
						SVN::Client::get_simple_provider(),
						SVN::Client::get_simple_prompt_provider(\&svn_simple_prompt, 10)
					]);
				my $svn_props = $svn_ctx -> proplist ($application_src . '/trunk', 'HEAD', 0);
				last unless ($is_svn_error);
				$is_svn_error = 0;
				print "Bad SVN repository url. Try again\n";
			}
		}
		print "\n";
		
		$appname_src = 'sample';
		if ($application_src !~ 'sample') {
			$application_src =~ m{.*\://[^/]+/([^/]+)};
			my $appname_src_dflt = $1;
			while (1) {
				$appname_src = $term -> readline ("Source application name (lowercase): [$appname_src_dflt]: ");
				$appname_src = $appname_src_dflt unless $appname_src;

				last if $appname_src =~ /[a-z_]+/
			}
		}

# source - svn repository
		unless ($application_src eq 'pub_sample') {
			$application_src =~ m{(.*\://[^/]+)};
			my $svn_server_url = $1;
			my $default_url = "$svn_server_url/$appname";
			if ($appname eq $appname_src) {
				my $default_url = 'same';
			}
			print "\nApplication's SVN repository destination\n\tnone - don't create\n\tsame - don't create branch, leave source repository url (only when application name equal source application name)\n\turl - create new branch at url location\n";
			while (1) {
				$application_dst = $term -> readline ("[$default_url]: ");
				$application_dst = $default_url unless $application_dst;
				
				if ($application_dst eq 'same' && $appname ne $appname_src) {
					print "Can't use the same repository url: application name not equal source application name. Try again\n";
				} else {
					unless ($application_dst eq 'none' || $application_dst eq 'same') {
						my $svn_props = $svn_ctx -> proplist ($application_dst . '/trunk', 'HEAD', 0);
						last if $is_svn_error == $SVN::Error::NODE_UNKNOWN_KIND;
						print "Bad or busy SVN repository url. Try again\n";
					} else {
						last;
					}
				}
			}
		}
		
		
		$appname_src_uc = uc $appname_src;	
		
		$password = random_password ();

		print <<EOT;
		
			Application name:	$appname
			User group:		$group
			Database name:		$db
			Database user:		$user
			Application template source:	$application_src
			SVN repository destination:	$application_dst
			Source application name:	$appname_src_uc
EOT
			
		my $ok = $term -> readline ("Everything in its right place? (yes/NO): ");
		
		last if $ok eq 'yes';
		
	}
	
	print "Creating database... ";
		
	$dbh -> do ("CREATE DATABASE $db");
	$dbh -> do ("GRANT ALL ON $db.* to $user\@localhost identified by '$password'");
	
	$dbh -> disconnect;	
	
	print "ok\n";

	print "Creating application directory... ";	
	if ($^O eq 'MSWin32') {
		`md $instpath`;
	}
	else {
		`mkdir $instpath`;
	}	
	print "ok\n";

	print "Copying application files... ";
	if ($^O eq 'MSWin32') {
		chdir $instpath;
		eval 'require Archive::Tar;';
		my $tar = Archive::Tar -> new ();
		$tar -> read ($path, 1);
		if ($application_src eq 'pub_sample') {
# static template
			$tar -> extract ($tar -> list_files ());
		} else {
			$tar -> extract ([(grep {$_ =~ /^(conf)|(logs)|(snapshots)|(sql)/} @{$tar -> list_files ()})]);
		}
	} else {
		if ($application_src eq 'pub_sample') {
			`tar xzfm $path --directory=$instpath/`;
		} else {
			`tar xzfm $path --directory=$instpath/ conf logs snapshots sql`;
		}
	}
	
	if ($application_src ne 'pub_sample' && $application_dst ne 'none' && $application_dst ne 'same') {
# Create branch
		$svn_ctx -> mkdir ("$application_dst");
		$svn_ctx -> mkdir ("$application_dst/tags");
		$svn_ctx->copy ($application_src . '/trunk', 'HEAD', "$application_dst/trunk");
		$svn_ctx->checkout("$application_dst/trunk", $instpath, 'HEAD', 1);
	} elsif ($application_dst eq 'same' || $application_dst eq 'none') {
		$svn_ctx->checkout("$application_src/trunk", $instpath, 'HEAD', 1);
		if ($application_dst eq 'none') {
# Delete SVN system files
			find (sub {`rm -rf $File::Find::name` if $File::Find::name =~ /\.svn$/}, "$instpath");
		}
	}
	print "ok\n";

	print "Renaming application files... ";
	if ($application_src ne 'pub_sample' && $application_dst ne 'none' && $application_dst ne 'same') {
		$svn_ctx->move ("$instpath/lib/$appname_src_uc", 'HEAD', "$instpath/lib/$appname_uc", 1);
		$svn_ctx->move ("$instpath/lib/$appname_src_uc.pm", 'HEAD', "$instpath/lib/$appname_uc.pm", 1);
	} elsif ($appname_src ne $appname) {
		if ($^O eq 'MSWin32') {
			rename "$instpath\\lib\\$appname_src_uc", "$instpath\\lib\\$appname_uc";
			rename "$instpath\\lib\\$appname_src_uc.pm", "$instpath\\lib\\$appname_uc.pm";
		} else {
			`mv $instpath/lib/$appname_src_uc $instpath/lib/$appname_uc`;
			`mv $instpath/lib/$appname_src_uc.pm $instpath/lib/$appname_uc.pm`;
		}	
	}
	print "ok\n";
	
	our %substitutions = (
		$appname_src_uc => $appname_uc,
	);
	
	if ($^O eq 'MSWin32') {
		find (\&fix, "$instpath\\lib");
	}
	else {
		find (\&fix, "$instpath/lib");
	}	

	%substitutions = (
		"/var/projects/$appname_src" => $instpath,
		'/var/vh/$appname_src' => $instpath,
		"=$appname_src" => '=' . $appname,
		$appname_src_uc => $appname_uc,
		"db_user => 'do'" => "db_user => '$user'",
		"db_password => 'z'" => "db_password => '$password'",
	);
	
	if ($^O eq 'MSWin32') {
		find (\&fix, "$instpath\\conf");
	}
	else {
		find (\&fix, "$instpath/conf");
	}	
	
	if ($^O ne 'MSWin32') {
		`chgrp -R $group $instpath`;	
		`chmod -R a+w $instpath`;
	}

	if ($application_src ne 'pub_sample' && $application_dst ne 'none' && $application_dst ne 'same') {
		$svn_ctx -> commit (["$instpath/lib", "$instpath/docroot"], 0);
	}
	print <<EOT;

--------------------------------------------------------------------------------
Congratulations! A brand new bare bones Zanas.pm-based WEB application is 
insatlled successfully. 

Now you just have to add it to your Apache configuration. This may look 
like
	
	Listen 8000
	
	<VirtualHost _default_:8000>
		Include "$instpath/conf/httpd.conf"
	</VirtualHost>
	
in /etc/apache/httpd.conf. Don\'t forget to restart Apache. 

Best wishes. 

d.o.
--------------------------------------------------------------------------------

EOT

}
#'

################################################################################

sub svn_import {

	_cd ();
	-f 'conf/httpd.conf' or die "ERROR: httpd.conf not found. Please, first chdir to the webapp directory.\n";

	my $instpath = `pwd`;
	chomp ($instpath);
	$instpath =~ m{([^/]+)$};
	my $appname = $1;
	my $svn_server_url = 'svn://svn.zanas.ru';


	eval 'require SVN::Client;';
	our ($is_svn_error, $svn_error_str);
	$SVN::Error::handler = \&svn_error_handler;
	my $svn_ctx = new SVN::Client(
		auth => [
			SVN::Client::get_simple_provider(),
			SVN::Client::get_simple_prompt_provider(\&svn_simple_prompt, 10)
		]);

	our $term = new Term::ReadLine 'Zanas application installation';

	while (1) {
		$application_dst = $term -> readline ("Application's SVN repository destination [$svn_server_url/$appname]: ");
		$application_dst = "$svn_server_url/$appname" unless $application_dst;

		my $svn_props = $svn_ctx -> proplist ($application_dst . '/trunk', 'HEAD', 0);
		last if $is_svn_error == $SVN::Error::NODE_UNKNOWN_KIND;
		print "Bad or busy SVN repository url. Try again\n";
	}
		
	backup_local ();

	find (sub {`rm -rf $File::Find::name` if $File::Find::name =~ /\.svn$/}, "$instpath");
	print "Importing application files... ";
	$svn_ctx -> mkdir ("$application_dst");
	$svn_ctx -> mkdir ("$application_dst/tags");
	$svn_ctx -> mkdir ("$application_dst/trunk");
	$svn_ctx -> mkdir ("$application_dst/trunk/docroot");
	$svn_ctx -> mkdir ("$application_dst/trunk/docroot/i");

	opendir (DIR, 'docroot/i') || die "can't opendir docroot/i: $!";
	map {
		unless ($_ =~ /upload/ || $_ eq '.' || $_ eq '..') {
#			print "$_\n";
			my $result = $svn_ctx -> import ("$instpath/docroot/i/$_", "$application_dst/trunk/docroot/i/$_", 0) ;
			die "Error importing directory $_\n" unless ($result);
		}
	} readdir (DIR);
	closedir (DIR);
	
	my $result = $svn_ctx -> import ("$instpath/lib", "$application_dst/trunk/lib", 0);
	die "Error importing directory $instpath/lib\n" unless ($result);
	mkdir "docroot_save";
	opendir (DIR, 'docroot') || die "can't opendir docroot: $!";
	map {
		unless ($_ eq 'i' || $_ eq '.' || $_ eq '..') {
		    `mv docroot/$_ docroot_save/$_`;
		}
	} readdir (DIR);
	closedir (DIR);

	if (-d "docroot/i/upload") {
	    mkdir 'docroot_save/i'; 
	    `mv docroot/i/upload docroot_save/i/`;
	}
        `rm -rf $instpath/docroot`;
	`rm -rf "$instpath/lib"`;

	$svn_ctx->checkout("$application_dst/trunk", "$instpath", 'HEAD', 1);

	`cp -r docroot_save/* docroot/`;
	`rm -rf docroot_save`;

	print "ok\n";

}

################################################################################

sub svn_commit {

	_cd ();
	-f 'conf/httpd.conf' or die "ERROR: httpd.conf not found. Please, first chdir to the webapp directory.\n";
	our $term = new Term::ReadLine 'Zanas application installation';

	
	eval 'require SVN::Client;';
	our ($is_svn_error, $svn_error_str);
	$SVN::Error::handler = \&svn_error_handler;

	my $svn_ctx = new SVN::Client(
		auth => [
			SVN::Client::get_simple_provider(),
			SVN::Client::get_simple_prompt_provider(\&svn_simple_prompt, 10)
		]);
	my $tag;
	my $url = $svn_ctx -> url_from_path('lib');
	$url || die 'Application is unversioned.';
	$url =~ s{/trunk/lib$}{};

        my $tag = $term -> readline ('Tag version as testing? (yes/NO): ');
                
	my $cnt = 0;
	for my $path ('lib', 'docroot/i') {
#		print "path: $path\n";
		$svn_ctx -> status ($path, 'HEAD', 
			sub {
				my ($file, $status) = @_; 
				next if ($file =~ m{/i/upload});
#				print "$file: ";
				if ($status -> text_status() == $SVN::Wc::Status::unversioned) {
					$cnt ++;
#					print "unversioned\n";
					$svn_ctx -> add ($file, 1);
				} elsif ($status -> text_status() == $SVN::Wc::Status::obstructed) {
					$cnt ++;
#					print "obstructed\n";
				} elsif ($status -> text_status() == $SVN::Wc::Status::missing) {
					$cnt ++;
#					print "missing\n";
					$svn_ctx -> delete ($file, 1);
				} elsif ($status -> text_status() == $SVN::Wc::Status::modified) {
					$cnt ++;
#					print "modified\n";
				} elsif ($status -> text_status() == $SVN::Wc::Status::normal) {
#					print "normal\n";
				} else {
#					print $status -> text_status() . "\n";
					$cnt ++; # �����, ����������� ��� ��������� �����
				}
			}, 
	# recursive
			1, 
	# retrieve all entries
			1, 
	# contact the repository
			1, 
	# disregard default and svn:ignore property ignores
			0);
	}

	my $result;
	if ($cnt > 0) {
	    our $log_message;
	    $svn_ctx -> log_msg(\&solicit);
            $result = $svn_ctx -> commit(['lib', 'docroot'], 0);
	    unless ($result) {
	        print "Commit error: $svn_error_str\n";
		return;
	    }
	} else {
	    print "Nothing commit\n";
	}

	if ($tag eq 'yes') {
	    $svn_ctx -> log_msg(undef);
	    my $revision = $result && $result->revision();
	    if (!$revision || $revision == $SVN::Core::INVALID_REVNUM) {
		my $dir = $svn_ctx->ls("$url", 'HEAD', 0);
		$revision = $dir -> {trunk} -> created_rev();
#	        $revision = ($svn_ctx->revprop_list("$url/trunk", 'HEAD')) [1];
	    
	    }
	    print "Current revision: $url/trunk/lib: $revision\n";
	    
	    $is_svn_error = 0;
            my $svn_props = $svn_ctx -> proplist ("$url/tags/testing_$revision", 'HEAD', 0);
            if ($is_svn_error == 0) {
		print "Current revision is already tagged as testing\n";
	    } else {
	        $svn_ctx->copy ("$url/trunk", $revision, "$url/tags/testing_$revision");
	    }
	}

	print "ok\n";
}

################################################################################

sub svn_update {
	my $rev = shift;
	
	$rev ||= 'HEAD';
	
	_cd ();
	-f 'conf/httpd.conf' or die "ERROR: httpd.conf not found. Please, first chdir to the webapp directory.\n";

	eval 'require SVN::Client;';
	our ($is_svn_error, $svn_error_str);
	$SVN::Error::handler = \&svn_error_handler;
	my $svn_ctx = new SVN::Client(
		auth => [
			SVN::Client::get_simple_provider(),
			SVN::Client::get_simple_prompt_provider(\&svn_simple_prompt, 10)
		]);

	$svn_ctx -> update ('lib', $rev, 1);
}

################################################################################
sub svn_simple_prompt {
	my $cred = shift;
	my $realm = shift;
	my $default_username = shift;
	my $may_save = shift;
	my $pool = shift;

	my $username = $term -> readline ("SVN repository user [$ENV{USER}]: ");
	$username = $ENV{USER} unless ($username);
	$cred->username($username);
	my $password = $term -> readline ("SVN repository password: ");
	$cred->password($password);
}

################################################################################
sub svn_error_handler {
	my $svn_error = shift;
	$is_svn_error = $svn_error -> apr_err();
	$svn_error_str = $svn_error -> strerror();
#	print "$svn_error_str: $is_svn_error\n";
	$svn_error->clear();
}

################################################################################

sub fix {

	my $fn = $File::Find::name;
	
	return unless $fn =~ /\.(pm|conf)$/;
	
	print "Fixing $fn...";
	
	open (IN, $fn) or die ("Can't open $fn: $!\n");
	open (OUT, '>' . $fn . '~') or die ("Can't write to $fn\~: $!\n");
	
	while (my $s = <IN>) {
		
		while (my ($from, $to) = each %substitutions) {
				
			$s =~ s{$from}{$to}g;
			
		}
		
		print OUT $s;
		
	}

	close (OUT);
	close (IN);
	
	unlink $fn;
	rename $fn . '~', $fn;
	
	print "ok\n";

}

################################################################################


sub solicit {
	my ($msg, $file_path, $objects) = @_;
#	print STDERR "solicit\n";
	
	my $info = "--This line, and those below, will be ignored--\n\n";
	
	File::Temp->safe_level(2);
	my ( $tfh, $filename ) = tempfile( UNLINK => 1 );

	unless ( $tfh and $filename ) {
		die "\nno temporary file\n";
	}

	select( ( select($tfh), $|++ )[0] );

	foreach my $obj (@$objects) {
		my $flag = $obj->state_flags();
		my $status = 
			$flag & $SVN::Client::COMMIT_ITEM_ADD ? 'A' :
			$flag & $SVN::Client::COMMIT_ITEM_DELETE ? 'D' :
			$flag & $SVN::Client::COMMIT_ITEM_TEXT_MODS  ? 'M' : '';
			
		$info .= ($status || $flag) . "\t" . $obj -> path() . "\n";
	}
	print $tfh $info;

	my $editor = (-x $ENV{SVN_EDITOR} && $ENV{SVN_EDITOR}) || (-x $ENV{VISUAL} && $ENV{VISUAL}) || (-x $ENV{EDITOR} && $ENV{EDITOR}) || 'vi';
	if ($^O eq 'MSWin32') {
		$editor = 'notepad.exe';
	}
	# need to unlock for external editor
	flock $tfh, LOCK_UN;

	my $status = system $editor, $filename;

	if ( $status != 0 ) {
		die ( $status != -1 ) ? 
			"external editor failed: editor=$editor, errno=$?"
		     : "could not launch program: editor=$editor, errno=$!";
	}

	unless ( seek $tfh, 0, 0 ) {
		die "could not seek on temp file: errno=$!";
	}
	
	$$msg = join '', <$tfh>;
	$$msg =~ s/$info.*//s;
	$log_message = $$msg;

	$$msg =~ s/\r//g;
	my  $converter = Text::Iconv->new("WINDOWS-1251", "UTF8");	
	$$msg = $converter -> convert($$msg);
	
#	return;
}


################################################################################

sub random_password {

	my $password;
	my $_rand;

	my $password_length = $_[0];
	if (!$password_length) {
		$password_length = 10;
	}

	my @chars = split(/\s/,
	"a b c d e f g h i j k l m n o p q r s t u v w x y z 
	 A B C D E F G H I J K L M N O P Q R S T U V W X Y Z
	 - _ % # |
	 0 1 2 3 4 5 6 7 8 9");

	srand;

 	for (my $i = 0; $i <= $password_length; $i++) {
		$_rand = int (rand 67);
		$password .= $chars [$_rand];
	}
	
	return $password;
	
}

package Zanas::Install;

$VERSION = 0.60;

BEGIN {
    $SIG {__DIE__} = \&Carp::confess;
}

=head1 NAME

Zanas::Install - create/update/backup/restore Zanas.pm based WEB applications.

=head1 SYNOPSIS

	
	#perl -MZanas::Install -e create 

		create a new application

	#cd /path/to/myapp/
	#perl -MZanas::Install -e backup
	
		or

	#perl -MZanas::Install -e backup [myapp]

		create a backup (db dump and libs) in /path/to/app/snapshots/

	#cd /path/to/myapp/
	#perl -MZanas::Install -e restore 2004-1-1-0-0-0

		or

	#perl -MZanas::Install -e restore [myapp] 2004-1-1-0-0-0

		restore /path/to/myapp/snapshots/2004-1-1-0-0-0.tar.gz

	#cd /path/to/myapp/
	#perl -MZanas::Install -e backup_master 

		or

	#perl -MZanas::Install -e backup_master [myapp]

		# create a backup on master server

	#cd /path/to/myapp/
	#perl -MZanas::Install -e sync_down 

		or

	#perl -MZanas::Install -e sync_down [myapp]

		# create a backup on master and then restore it on local server

	#cd /path/to/myapp/
	#perl -MZanas::Install -e sync_up

		or

	#perl -MZanas::Install -e sync_up [myapp]

		# packs libs on local and then restore it on master server
		

=head1 DESCRIPTION

Zanas::Install is a set of tools to maniputate Zanas.pm based WEB applications. Its aim is to 
automate common support tasks like copying/renaming multiple *.pm files, dumping/restoring
databases et caetera.

=head2 Creating a new application

No more need to manually create MySQL database, set permissions and clone *.pm library
from existing application. Simply punch C<perl -MZanas::Install -e create> and enter
all asked values interactively.

At the end of this process you'll need to perform the only administrative task: link
the new created application specific C<httpd.conf> from the global Apache configuration.

=head2 Backup/restore

You can take the snapshot of the working application, store it locally and then restore.
The snapshot consists of the database dump and all files in lib/ directory. 

On the command C<backup> all of it is packed, named $year-$month-$day-$hour-$minute-$second.tar.gz and 
then stored in C<snapshots> directory. This gzipped tar is then symlinked as C<latest.tar.gz>.

On the command C<restore $year-$month-$day-$hour-$minute-$second> the old state returns.
Don't worry, the current state is automatically backed up before each restore. If no
snapshot label is given then C<latest.tar.gz> is restored.

=head2 Replication.

It's common case when an application exists in different places in different versions.
Say, you have development, testing and production servers. As usual, you have to
mirror down the testing and the production snaphots to the development server and replicate
the development libraries up to the testing and the production servers.

Each Zanas based application can have a 'master': testing insatllation is a master one
for development and production insatllation is a master one for testing. The master
insatllation is pointed in httpd.conf file as follows:

	<perl> 

		...

		our $preconf = {

			...
		
			master_server => {
				user => 'ssh_user',
				host => 'ssh_host',
				path => '/path/on/remote/server',
			}, 

	   };  

	</perl>

Now if the host is accessible with the SSH protocol without the password (key pairs are OK) or 
C<ssh_host eq 'localhost'> you can replicate the application up and down.

The C<sync_down> command generates the application snapshot on the master, copies it
to the local server and restores it here.

The C<sync_up> command packs local libraries, copies it to the master
server and unpacks it here.

Note that only code goes up: production data will not be overriden. The database
scheme shoud be synced with DBIx::ModelUpdate.

=head1 HOW APPLICTATION SETTINGS ARE FETCHED

Without [myapp] arg set Zanas::Install reads the settings from C<conf/httpd.conf>
and lib/MYAPP/Config.pm files (as of current version, only lib/MYAPP/Config.pm matters, 
this is to know the application libraries name).

When [myapp] arg is given, Zanas::Install trys to guess where your application directory 
is hidden and chdir there. To do so, C<apache> or C<httpd> is asked for the default conf
file location, then this last is parsed for C<Include .../myapp/conf/httpd.conf>. If 
httpd.conf is located somewhere else, Zanas::Install currently dies with an error message.

=head1 [DON'T] PANIC SCENARIOS

=head2 Wrong backup restored

	#perl -MZanas::Install -e restore [myapp] 2004-1-1-0-0-0

Oh, my! I've lost everything from the New Year!.. Hm, wait a minute... No, I really can undo it!

	#perl -MZanas::Install -e restore [myapp]

=head2 Old shit from master server

	#perl -MZanas::Install -e sync_down [myapp]

Oh, my! I've lost everything from the past release!.. Hm, wait a minute... No, I really can undo it!

	#perl -MZanas::Install -e restore [myapp]

=head2 Premature release

	#perl -MZanas::Install -e sync_up [myapp]

Oh, my! It's buggy! The master app will be broken! Hm, wait a minute... No, I really can undo it!

	#perl -MZanas::Install -e restore_master_libs [myapp]

=head1 SEE ALSO

Zanas

=head1 AUTHORS

Dmitry Ovsyanko <do@zanas.ru>

=cut

1;
