use ExtUtils::MakeMaker;
WriteMakefile(
    'NAME'		=> 'Zanas::Install',
    'VERSION_FROM'	=> 'lib/Zanas/Install.pm',
#    'VERSION_FROM'	=> 'Zanas/Install.pm',
    'PREREQ_PM'		=> {
	'DBI'			=> '1.21',
	'DBD::mysql'		=> '2.9002',
	'Term::ReadPassword'	=> '0.01',
    },
    ($] >= 5.005 ?    
	(
	ABSTRACT_FROM => 'lib/Zanas/Install.pm', 
#	ABSTRACT_FROM => 'Zanas/Install.pm', 
	AUTHOR     => 'D. Ovsyanko <do@zanas.ru>') : ())
);
