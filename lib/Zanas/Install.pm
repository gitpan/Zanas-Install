package Zanas::Install;

package main;

use Term::ReadLine;
use Term::ReadPassword;
use File::Find;
use DBI;
use Data::Dumper;

################################################################################

sub _local_exec {

print STDERR "[$_[0]]\n";

	print `$_[0]`;
	
}

################################################################################

sub _master_exec {

	my ($preconf, $cmd) = @_;
	
	my $ms = $preconf -> {master_server};
	my $ex = $ms -> {host} eq 'localhost' ? $cmd : "ssh -l$$ms{user} $$ms{host} '$cmd'";

print STDERR "[$ex]\n";
	
	my $stdout = `$ex`;
	
	print $stdout;

	return $stdout;

}

################################################################################

sub restore_local_libs {
	my ($path) = @_;
	$path ||= $ARGV [0];
	print " Zanas::Install> Removing libs...\n";
	_local_exec ("rm -rf lib/Content/*");
	_local_exec ("rm -rf lib/Presentation/*");
	print " Zanas::Install> Unpacking $path...\n";
	_local_exec ("tar xzvf $path");
	_local_exec ("chmod -R a+rwx lib/*");
}

################################################################################

sub restore_local_db {

	my ($path) = @_;	
	$path ||= $ARGV [0];

	my $local_preconf = _read_local_preconf ();
	
	print " Zanas::Install> Unzipping $path...\n";
	_local_exec ("gunzip $path");
	$path =~ s{\.gz$}{};
	
	print " Zanas::Install> Feeding $path to MySQL...\n";

	_local_exec ("mysql -u$$local_preconf{db_user} -p$$local_preconf{db_password} $$local_preconf{db_name} < $path");

	print " Zanas::Install> DB restore complete.\n";
	
}

################################################################################

sub restore {
	restore_local (@_);
}

################################################################################

sub restore_local {

	my ($time) = @_;
	$time ||= $ARGV [0];
	
#print STDERR "restore_local: \$time (1) = $time\n";

	$time =~ s{snapshots\/}{};
	$time =~ s{\.tar\.gz}{};

#print STDERR "restore_local: \$time (2) = $time\n";
	
	my $path = "snapshots/$time.tar.gz";
	-f $path or die "File not found: $path\n";
	_log ("Restoring $path on local server...");
	_log ("Unpacking $path...");
	_local_exec ("tar xzvf $path");

	$time =~ s{master_}{};

#print STDERR "restore_local: \$time (3) = $time\n";

	my $local_conf = _read_local_conf ();
	my $lib_path = 'lib/' . $local_conf -> {application_name} . '.' . $time . '.tar.gz';
	restore_local_libs ($lib_path);
	_log ("Removing $lib_path...");
	_local_exec ("rm $lib_path");
	
	my $local_preconf = _read_local_preconf ();
	my $db_path = 'sql/' . $local_preconf -> {db_name} . '.' . $time . '.sql.gz';
	restore_local_db ($db_path);
	$db_path =~ s{\.gz$}{};
	_log ("Removing $db_path...");
	_local_exec ("rm $db_path");
	
}

################################################################################

sub _db_path {
	my ($db_name, $time) = @_;
	$time ||= time;
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday) = gmtime ($time);
	$mon ++;
	$year += 1900;
	return "sql/$db_name.$year-$mon-$mday-$hour-$min-$sec.sql";
}

################################################################################

sub _lib_path {
	my ($application_name, $time) = @_;
	$time ||= time;
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday) = gmtime ($time);
	$mon ++;
	$year += 1900;
	return "lib/$application_name.$year-$mon-$mday-$hour-$min-$sec.tar.gz";
}

################################################################################

sub _snapshot_path {
	my ($time) = @_;
	$time ||= time;
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday) = gmtime ($time);
	$mon ++;
	$year += 1900;
	return "snapshots/$year-$mon-$mday-$hour-$min-$sec.tar.gz";
}

################################################################################

sub backup {
	backup_local (@_);
}

################################################################################

sub backup_local {

	my ($time) = @_;
	$time ||= time;
	_log ("Backing up application on local server...");
	my $db_path = backup_local_db ($time);
	my $libs_path = backup_local_libs ($time);
	my $path = _snapshot_path ($time);
	
	_log ("Creating $path...");
	_local_exec ("tar czvf $path $db_path $libs_path");
	
	_log ("Removing $db_path...");
	_local_exec ("rm $db_path");
	
	_log ("Removing $libs_path...");
	_local_exec ("rm $libs_path");
	
	_log ("Backup complete");
	return $path;
	
}

################################################################################

sub sync_down {

	my $snapshot_path = backup_master ();

print STDERR "sync_down: \$snapshot_path = $snapshot_path\n";
	
	my $local_conf = _read_local_conf ();		
	my $local_preconf = _read_local_preconf ();
	_log ("Copying $snapshot_path from master...");
	_cp_from_master ($local_preconf, $local_preconf -> {master_server} -> {path} . '/' . $snapshot_path, 'snapshots/');
	
	restore_local ($snapshot_path);

	_log ("Sync complete");

}

################################################################################

sub _log {

	print " $_[0]\n";

}

################################################################################

sub sync_up {

	my $libs_path = backup_local_libs ();

	my $local_conf = _read_local_conf ();		
	my $local_preconf = _read_local_preconf ();
	my $master_path = $local_preconf -> {master_server} -> {path};

	_log ("Copying $libs_path to master...");
	_cp_to_master ($local_preconf, $libs_path, $local_preconf -> {master_server} -> {path} . '/' . $libs_path);

	_log ("Removing $libs on master...");
	_master_exec ($local_preconf, "cd $master_path; rm -rf libs/*");

	_log ("Unpacking $libs on master...");
	_master_exec ($local_preconf, "cd $master_path; tar xzvf $libs_path");

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
	
	my $local_conf = _read_local_conf ();	
	my $local_preconf = _read_local_preconf ();	
	my $master_preconf = _read_master_preconf ();
	my $master_path = $local_preconf -> {master_server} -> {path};
	
	my $db_path = backup_master_db ($time);
	$db_path =~ s{$master_path\/}{};
	
	my $libs_path = backup_master_libs ($time);
	$libs_path =~ s{$master_path\/}{};	
	
	my $path = _snapshot_path ($time);
	$path =~ s{snapshots\/}{snapshots\/master_};
	
	_log ("Creating $path...");
	_master_exec ($local_preconf, "cd $master_path; tar czvf $master_path/$path $db_path $libs_path");
	
	_log ("Removing $db_path...");
	_master_exec ($local_preconf, "cd $master_path; rm $db_path");
	
	_log ("Removing $libs_path...");
	_master_exec ($local_preconf, "cd $master_path; rm $libs_path");
	
	_log ("Backup complete");
	
print STDERR "backup_master: \$path = $path\n";

	return $path;
	
}

################################################################################

sub backup_local_db {

	my ($time) = @_;
	$time ||= time;
	my $local_preconf = _read_local_preconf ();	
	my $path = _db_path ($local_preconf -> {db_name}, $time);
	_log ("Backing up db $$local_preconf{db_name} on local server...");
	
	_log ("Creating $path...");
	_local_exec ("mysqldump --add-drop-table -u$$local_preconf{db_user} -p$$local_preconf{db_password} $$local_preconf{db_name} > $path");
	
	_log ("Gzipping $path...");
	_local_exec ("gzip $path");
	
	_log ("DB backup complete");
	return "$path.gz";
		
}

################################################################################

sub backup_master_db {

	my ($time) = @_;
	$time ||= time;	
	my $local_conf = _read_local_conf ();	
	my $local_preconf = _read_local_preconf ();	
	my $master_preconf = _read_master_preconf ();	
	my $path = $local_preconf -> {master_server} -> {path} . '/' . _db_path ($local_preconf -> {db_name}, $time);
	_log ("Backing up db $$master_preconf{db_name} on master server...");
	_log ("Creating $path...");
	_master_exec ($local_preconf, "mysqldump --add-drop-table -u$$master_preconf{db_user} -p$$master_preconf{db_password} $$master_preconf{db_name} > $path");
	_log ("Gzipping $path...");
	_master_exec ($local_preconf, "gzip $path");
	_log ("DB backup complete");
	return "$path.gz";
		
}

################################################################################

sub backup_local_libs {

	my ($time) = @_;
	$time ||= time;
	my $local_conf = _read_local_conf ();
	my $path = _lib_path ($local_conf -> {application_name}, $time);

	_log ("Backing up libs on local server...");
	_local_exec ("tar czvf $path lib/*");

	_log ("Lib backup complete");
	return $path;
		
}

################################################################################

sub backup_master_libs {

	my ($time) = @_;
	$time ||= time;
	my $master_conf = _read_master_conf ();
	my $local_conf = _read_local_conf ();
	my $local_preconf = _read_local_preconf ();
	my $path = $local_preconf -> {master_server} -> {path} . '/' . _lib_path ($local_conf -> {application_name}, $time);

	_log ("Backing up libs on master server...");
	_master_exec ($local_preconf, 'cd ' . $local_preconf -> {master_server} -> {path} . "; tar czvf $path lib/*");

	_log ("Lib backup complete");
	return $path;
		
}

################################################################################

sub _read_master_conf {

	my $local_conf = _read_local_conf ();
	my $local_preconf = _read_local_preconf ();
	my $src = _master_exec ($local_preconf, 'cat ' . $local_preconf -> {master_server} -> {path} . "/lib/$$conf{application_name}/Config.pm");
	undef $conf;
	eval $src;
	return $conf;

}

################################################################################

sub _read_master_preconf {

	my $local_conf = _read_local_conf ();
	my $local_preconf = _read_local_preconf ();
	my $src = _master_exec ($local_preconf, 'cat ' . $local_preconf -> {master_server} -> {path} . "/conf/httpd.conf");
	return _decrypt_preconf ($src);
	
}

################################################################################

sub _read_local_conf {
	
	opendir (DIR, 'lib') || die "can't opendir lib: $!";
	my ($appname) = grep {(-d "lib/$_") && ($_ !~ /\./) } readdir (DIR);
	closedir DIR;
	do "lib/$appname/Config.pm";
	$conf -> {application_name} = $appname;
	return $conf;	
	
}

################################################################################

sub _decrypt_preconf {
	my ($src) = @_;
	$src =~ /\$preconf.*?\;/gsm;
	$src = $&;
	eval $src;
	$preconf -> {db_dsn} =~ /database=(\w+)/;
	$preconf -> {db_name} = $1;
	return $preconf;
}

################################################################################

sub _read_local_preconf {

	my $src = `cat conf/httpd.conf`;
	return _decrypt_preconf ($src);
	$src =~ /\$preconf.*?\;/gsm;
	
}

################################################################################

sub create {

	my $path = $INC{'Zanas/Install.pm'};
	
	$path =~ s{Install\.pm}{static/sample.tar.gz.pm};
	
	my $term = new Term::ReadLine 'Zanas application installation';
	
	my ($appname, $appname_uc, $instpath, $db, $user, $password, $group, $admin_user, $admin_password, $dbh);
	
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
		
		$password = random_password ();

		print <<EOT;
			Application name:	$appname
			User group:		$group
			Database name:		$db
			Database user:		$user
EOT
			
		my $ok = $term -> readline ("Everything in its right place? (yes/NO): ");
		
		last if $ok eq 'yes';
		
	}
	
	-d $instpath and die ("Can't proceed: installation path exists.\n");
		
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
		$tar -> extract ($tar -> list_files ());
	}
	else {
		`tar xzvf $path --directory=$instpath/`;
	}	
	print "ok\n";

	print "Renaming application files... ";
	if ($^O eq 'MSWin32') {
		rename "$instpath\\lib\\SAMPLE", "$instpath\\lib\\$appname_uc";
		rename "$instpath\\lib\\SAMPLE.pm", "$instpath\\lib\\$appname_uc.pm";
	}
	else {
		`mv $instpath/lib/SAMPLE $instpath/lib/$appname_uc`;
		`mv $instpath/lib/SAMPLE.pm $instpath/lib/$appname_uc.pm`;
	}	
	print "ok\n";
	
	our %substitutions = (
		SAMPLE => $appname_uc,
	);
	
	if ($^O eq 'MSWin32') {
		find (\&fix, "$instpath\\lib");
	}
	else {
		find (\&fix, "$instpath/lib");
	}	

	%substitutions = (
		'/var/projects/sample' => $instpath,
		'=sample' => '=' . $appname,
		SAMPLE => $appname_uc,
		"'do'" => "'$user'",
		"'z'" => "'$password'",
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

$VERSION = 0.5;

=head1 NAME

Zanas::Install - create/update/backup/restore Zanas.pm based WEB applications.

=head1 SYNOPSIS

	
	#perl -MZanas::Install -e create 

		# create a new application

	#cd /path/to/app/
	#perl -MZanas::Install -e backup

		# create a backup (db dump and libs) in /path/to/app/snapshots/

	#cd /path/to/app/
	#perl -MZanas::Install -e restore 2004-1-1-0-0-0

		# restore /path/to/app/snapshots/2004-1-1-0-0-0.tar.gz

	#cd /path/to/app/
	#perl -MZanas::Install -e backup_master 

		# create a backup on master server

	#cd /path/to/app/
	#perl -MZanas::Install -e sync_down 

		# create a backup on master and then restore it on local server

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
then stored in C<snapshots> directory.

On the command C<restore $year-$month-$day-$hour-$minute-$second> the old state returns.
B<Caution!> You are responsible to backup the current state before restore the old one.

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

=head1 SEE ALSO

Zanas

=head1 AUTHORS

Dmitry Ovsyanko <do@zanas.ru>

=cut

1;
