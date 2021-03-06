use 5.008000;
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    NAME              => 'Net::Z3950::FOLIO',
    VERSION_FROM      => 'lib/Net/Z3950/FOLIO.pm', # finds $VERSION
    PREREQ_PM         => {
	Net::Z3950::SimpleServer => 1.21,
	LWP::UserAgent => 6.05,
	Mozilla::CA => 20200520,
	Cpanel::JSON::XS => 4.08,
	MARC::Record => 2.0,
	MARC::File::XML => 1.0.5,
	Net::Z3950::ZOOM => 1.30,
	URI::Escape => 3.31,
	XML::Simple => 2.25,
	Net::Z3950::PQF => 1.0,
    },
    META_ADD => {
	no_index => {
	    namespace => [ 'Net::Z3950::RPN' ],
	},
    },
    ($] >= 5.005 ?     ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM  => 'lib/Net/Z3950/FOLIO.pm', # retrieve abstract from module
       AUTHOR         => 'Mike Taylor <mike@indexdata.com>') : ()),
);
