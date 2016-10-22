use v5.24;
use feature qw(signatures);
no warnings qw(experimental::signatures);

package Ghojo;
# The endpoints are divided into public and authenticated parts
# We'll use this inheritance chain to divide them. The public
# class can't see the stuff in the authorized class, but the
# authorized class can see the public stuff. The object that
# the user gets will be one of these.
#
# There could be higher levels for Access and Authorization
@Ghojo::PublicUser::ISA        = qw(Ghojo);
@Ghojo::AuthenticatedUser::ISA = qw(Ghojo::PublicUser);

sub AUTOLOAD ( $self ) {
	our $AUTOLOAD;

	my( $class, $method ) = do {
		if( $AUTOLOAD =~ m/(?<class>.*)::(?<method>.+)/ ) {
			@+{ qw(class method) };
			}
		else {
			() # How did we get here?
			}
		};

	# What about the case where the method hasn't been loaded?

	if( $self->authenticated_user_class->can( $method ) and not $self->handles_authenticated_api ) {
		$self->logger->error( "Method [$method] is part of the authenticated user API, but this object only handles the public API" );
		}
	}


our $VERSION = '1.001001';

use Mojo::Collection;
use Mojo::URL;

=encoding utf8

=head1 NAME

Ghojo - a Mojo-based interface to the GitHub Developer API

=head1 SYNOPSIS

	use Ghojo;

	# authenticated
	my $ghojo = Ghojo->new( {
		username => ...,
		password => ...,
		});

	# authenticated
	my $ghojo = Ghojo->new( {
		token => ...,
		} );

	# anonymous, not logged in
	my $ghojo = Ghojo->new( {} );

=head1 DESCRIPTION

Here's a Mojo-based interface to the GitHub Developer's API. I'm
reinventing L<Net::GitHub> and L<Pithub> because I feel like it. I
want to make something for the work I do in the way I like to do it,
but I'll let you use it. This started as a way to download all the
GitHub repo meta data for some analysis of label frequency, then it
got out of control for another customer.

My design goals are:

=over 4

=item * Keep a low dependency development model

=item * Make it easy for casual contributors (so no L<Dist::Zilla>)

=item * Supply a more sophisticated interface over a thin layer over the REST stuff

=item * Don't use Moo(se)? since most of the stuff I want to do is special

=item * Validate the inputs to the API to give better error messages

=item * Better response checking

=back

I'm implementing the parts of the API as I or my customers need them.

If you would like to play with this to change things on GitHub, I
suggest setting up a new user and some repos you don't care about
(perhaps forked from interesting ones). Play with those until you are
satisfied that this code isn't going to delete your life. I also keep
backup clones at Bitbucket just in case.

=cut

=head2 The API

	Activity
		Events
		Feeds
		Notifications
		Starring
		Watching

	Gists
		Comments

	Git Data
		Blobs
		Commits
		References
		Tags
		Trees

	Integrations
		Integrations
		Installations

	Issues
		Assignees
		Comments
		Events
		Labels
		Milestones
		Timeline

	Migration
		Migrations
		Source Imports

	Miscellaneous
		Emojis
		Gitignore
		Licenses
		Markdown
		Meta
		Rate Limit

	Organizations
		Members
		Teams
		Webhooks

	Pull Requests
		Review Comments

	Reactions
		Commit Comment
		Issue
		Issue Comment
		Pull Request Review Comment

	Repositories
		Branches
		Collaborators
		Comments
		Commits
		Contents
		Deploy Keys
		Deployments
		Downloads
		Forks
		Invitations
		Merging
		Pages
		Projects
		Releases
		Statistics
		Statuses
		Traffic
		Webhooks

	Search
		Repositories
		Code
		Issues
		Users
		Legacy Search

	Users
		Emails
		Followers
		Git SSH Keys
		GPG Keys
		Administration (Enterprise)

	Enterprise
		Admin Stats
		LDAP
		License
		Management Console
		Pre-receive Environments
		Pre-receive Hooks
		Search Indexing
		Organization Administration


=head2  General object thingys

=over 4

=item * new

You can create a new object with providing a username/password pair
or a previously created token.

	# Use a login pair. This will create a token for you.
	my $ghojo = Ghojo->new( {
		username => ...,
		password => ...,
		});

	# pass the token as a string
	my $ghojo = Ghojo->new( {
		token => ...,
		} )

	# read a saved token from a file
	my $ghojo = Ghojo->new( {
		token_file => ...,
		} )

	# look in default token file for saved token
	my $ghojo = Ghojo->new( {
		} )

To get a token, see "Personal Access Tokens" in your GitHub settings
(L<https://github.com/settings/tokens>). Be careful! As soon as you
create it GitHub will show you the token, but that's the last time
you'll see it.

With this constructor, Ghojo will create a new token for you (which will
show up in "Personal Access Tokens"). It will save it in the value
returned by C<token_file>.

=cut

sub new ( $class, $args = {} ) {
	# We start off with the public interface. If an authorization works
	# it will rebless the object for the authenticated class name.
	my $self = bless {}, $class->public_user_class;

	$self->setup_logging(
		$args->{logging_conf} ? $args->{logging_conf} : $class->logging_conf
	);

	if( exists $args->{token} ) {
		$self->logger->trace( 'Authenticating with token' );
		$self->add_token( $args->{token} );
		}
	elsif( exists $args->{token_file} ) {
		$self->logger->trace( 'Authenticating with saved token in named file' );
		$self->read_token( $args->{token_file} );
		}
	elsif( exists $args->{username} and exists $args->{password} ) {
		$self->logger->trace( 'Authenticating with username and password' );
		$args->{authenticate} //= 1;
		$self->login( $args );
		}
	elsif( -e $self->token_file ) {
		$self->logger->trace( 'Authenticating with saved token in default file' );
		$self->logger->trace( 'Reading token from file' );
		my $token = do { local( @ARGV, $/ ) = $self->token_file; <> };
		$self->logger->trace( "Token from default token_file is <$token>" );
		$self->add_token( $token );
		}

	$self;
	}

=item * class_name

Returns the class name of the object.

=cut

sub class_name ( $self ) { ref $self }

=item * handles_public_api

Returns true if the object can access the public API. This should
always be true, although there might be a time when we need it.

=item * handles_authenticated_api

Returns true if the object can access the authenticated portions of
the API. This does not guarantee access or authorization for a
particular endpoint though.

=cut

sub handles_public_api ( $self )     { $self->isa( $self->public_user_class ) }

sub handles_authenticated_api ( $self ) { $self->isa( $self->authenticated_user_class ) }

=item * test_authenticated

Returns true if the object is set up to access the authenticated user
parts of the the API. This will be false unless the object is not the
authenticated user class, but might also be false if it is the right
class but the authentication did not work or was revoked (deleted
token, GitHub ban, etc).

The C</rate_limit> endpoint returns different limits for the public
and authenticated user interface so that's a good way to check for now.

See L<https://developer.github.com/v3/rate_limit/>.

=cut

sub test_authenticated ( $self ) {
	return 0 unless $self->handles_authenticated_api;

	return 1 if $self->is_authenticated_api_rate_limit;

	return 0;
	}


=item * login

Login to GitHub to access the parts of the API that require an
authenticated user. You do not need to do this if you want to use the
public parts of the API.

	username  - (required) The GitHub username
	password  - (required) The GitHub password
	authenticate - (optional) If true, create a personal access token.
	            Default: true

If the login was successful, it returns

If you pass C<username> and C<password> to C<new>, Ghojo will
do this step for you.

=cut

sub login ( $self, $args={} ) {
	$self->{$_} = $args->{$_} for ( qw(username password) );
	$self->{last_tx} = $self->ua->get(
		$self->query_url( '/user' ) =>
		{ 'Authorization' => $self->basic_auth_string }
		);

	unless( $self->last_tx->success ) {
		my $err = $self->last_tx->error;
		my $otp_header = $self->last_tx->res->headers->header('x-github-otp') // '';
		$self->logger->warn( "authentication failed!" );
		$self->warnif( $err->{code}, "$err->{code} response: $err->{message}" );
		$self->warnif( my $flag = ($otp_header =~ /required/), "You seem to have 2fa setup for your account. Create an access token for use with Ghojo from https://github.com/settings/tokens" );

		# returns a object that can access the public interface
		return $self;
		}

	if ($args->{authenticate}) {
		$self->{last_tx} = $self->ua->get( $self->api_base_url );
		$self->create_authorization;
		delete $self->{password};
		}

	bless $self, $self->authenticated_user_class;
	}

=item * public_user_class

Returns the class name that comprises the parts of the API that
don't need an authenticate user. This is the public part of the interface
and is the default object type the C<< Ghojo->new >> returns if you
don't login.

=cut

sub public_user_class ( $self ) { 'Ghojo::PublicUser' }

=item * authenticate_user_class

Returns the class name that comprises the parts of the API that
require an authenticate user. After a successful C<login>, the Ghojo
object automatically reblesses itself to this class. It's a superset
of the public interface.

=cut

sub authenticated_user_class ( $self ) { 'Ghojo::AuthenticatedUser' }

=item * read_token

Read token from a file and save it in memory.

=cut

sub read_token ( $self, $token_file ) {
	open my $fh, '<:utf8', $token_file or do {
		$self->logger->error( "Could not read token file $token_file" );
		return;
		};
	chomp( my $token = <$fh> );

	# XXX: There should be something here to check that the string looks like a token
	$self->logger->debug( "Token from token_file is <$token>" );

	$self->add_token($token);

	$self;
	}

=item * get_repo_object

Get a repo object which remembers its owner and repo name so you don't
have to pass those parameters for all these general method. This is really
a wrapper around L<Ghojo> that fills in some arguments for you.

=cut

sub get_repo_object ( $self, $owner, $repo ) {
	state $rc = require Ghojo::Repo;
	my $perl = $self->get_repo( $owner, $repo );
	unless( $perl ) {
		$self->logger->error( "Could not find the $owner/$repo repo" );
		return;
		}

	my $obj = Ghojo::Repo->new_from_response( $self, $perl );
	unless( $obj ) {
		$self->logger->error( "Could not make object for $owner/$repo!" );
		return;
		}

	$obj;
	}

=back

=head2 Logging

If L<Log4perl> is installed, Ghojo will use that. Otherwise, it installed
the null logger in L<Ghojo::NullLogger>. That responds to all logging
messages but does nothing.

The constructor accepts the C<logging_conf> argument using the same rules as
C<logging_conf()>.

=over 4

=cut

sub setup_logging ( $self, $conf = __PACKAGE__->logging_conf ) {
	require Log::Log4perl;

	$self->{logger} = do {
		if( eval "require Log::Log4perl; 1" ) {
			Log::Log4perl::init( $conf );
			Log::Log4perl->get_logger;
			}
		else {
			# responds to all methods with nothing.
			Ghojo::NullLogger->new;
			}
		};
	}

=item * logging_conf

Returns the default configuration for L<Log::Log4perl>. If it returns
a non-reference scalar, L<Log::Log4perl> uses that string as the filename
for the configuration. If it's a reference,  L<Log::Log4perl> uses that
as a string that holds the configuration. You can override this method
in a subclass (or redefine it).

=cut

sub logging_conf ( $class, $level = $ENV{GHOJO_LOG_LEVEL} // 'OFF' ) {
	my $conf = qq(
		log4perl.rootLogger          = $level, Screen

		log4perl.appender.Logfile          = Log::Log4perl::Appender::File
		log4perl.appender.Logfile.filename = test.log
		log4perl.appender.Logfile.layout   = Log::Log4perl::Layout::PatternLayout
		log4perl.appender.Logfile.layout.ConversionPattern = [%r] %F %L %m%n

		log4perl.appender.Screen         = Log::Log4perl::Appender::Screen
		log4perl.appender.Screen.stderr  = 1
		log4perl.appender.Screen.layout = Log::Log4perl::Layout::SimpleLayout
		);

	\$conf;
	}

=item * logger

Returns the logger object. Wherever you want to log, you can get to the
logging object through the Ghojo object:

	$self->logger->debug( ... );

=cut

sub logger ( $self ) { $self->{logger} }

=item * enter_sub

Emit a trace message that we entered the subroutine. The message will
look the same everywhere we do this.

=cut

sub entered_sub ( $self ) {
	return unless $self->logger->is_trace;
	my @caller = caller(1);

	$self->logger->trace( "Entered $caller[0]\:\:$caller[3] in $caller[1] line $caller[2]" );
	}

=item * traceif( FLAG, MESSAGE )

=item * debugif( FLAG, MESSAGE )

=item * infoif( FLAG, MESSAGE )

=item * warnif( FLAG, MESSAGE )

=item * errorif( FLAG, MESSAGE )

=item * fatalif( FLAG, MESSAGE )

Like the L<Log4perl> methods but adds a FLAG argument. If that argument
is true, it passes on the log message (which still might be logged based
on the log level).

=cut

sub traceif ( $self, $flag, $message ) { $flag ? $self->logger->trace( $message )   : $flag }
sub debugif ( $self, $flag, $message ) { $flag ? $self->logger->debug( $message )   : $flag }
sub infoif  ( $self, $flag, $message ) { $flag ? $self->logger->info( $message )    : $flag }
sub warnif  ( $self, $flag, $message ) { $flag ? $self->logger->warn( $message )    : $flag }
sub errorif ( $self, $flag, $message ) { $flag ? $self->logger->logwarn( $message ) : $flag }
sub fatalif ( $self, $flag, $message ) { $flag ? $self->logger->logdie( $message )  : $flag }

=back

=head2 Rate Limiting

=cut

sub rate_limit_cache_time { 60 }

BEGIN {
	my $cache = [];
	sub set_rate_limit_cache   ( $self, $data ) { $cache = [ $data, time ] }
	sub get_rate_limit_cache   ( $self )        { $cache }
	sub clear_rate_limit_cache ( $self )        { $cache = [] }
	}

sub get_rate_limit ( $self ) {
	my $cache = $self->get_rate_limit_cache;

	if( ! defined $cache->[0] or time - $cache->[0] > $self->rate_limit_cache_time ) {
		my $url = $self->query_url( '/rate_limit' );
		$self->{last_tx} = $self->ua->get( $url );
		my $data = $self->last_tx->res->json;
		delete $data->{rate}; # delete because it's deprecated and we should never use it
		$cache = [ $data, time ];
		}

	$cache->[0];
	}

sub is_public_api_rate_limit ( $self ) { $self->core_rate_limit < 100 }

sub is_authenticated_api_rate_limit ( $self ) { $self->core_rate_limit == 5000 }

sub core_rate_limit ( $self ) {
	$self->get_rate_limit->{resources}{core}{limit};
	}

sub core_rate_limit_left ( $self ) {
	$self->get_rate_limit->{resources}{core}{remaining};
	}

sub core_rate_limit_percent_left ( $self ) {
	sprintf "%d",
		100
			*
		( $self->core_rate_limit - $self->core_rate_limit_left )
			/ #/
		$self->core_rate_limit;
	}

sub seconds_until_core_rate_limit_reset ( $self ) {
	$self->get_rate_limit->{resources}{core}{reset} - time
	}

sub search_rate_limit ( $self ) {
	$self->get_rate_limit->{resources}{search}{limit};
	}

sub search_rate_limit_left ( $self ) {
	$self->get_rate_limit->{resources}{search}{remaining};
	}

sub search_rate_limit_percent_left ( $self ) {
	sprintf "%d",
		100
			*
		( $self->search_rate_limit - $self->search_rate_limit_left )
			/ #/
		$self->search_rate_limit;
	}

sub seconds_until_search_rate_limit_reset ( $self ) {
	$self->get_rate_limit->{resources}{search}{reset} - time
	}

=head2 Authenticating queries

The GitHub API lets you authenticate through Basic (with username and password)
or token authentication. These methods handle most of those details.

=over 4

=cut

=item * logged_in_user

=item * username

=item * has_username

The C<username> and C<logged_in_user> are the same thing. I think the
later is more clear, though.

=item * password

=item * has_password

Note that after a switch to token authentication, the password might be
deleted from the object.

=item * token

=item * has_token

Fetch or check that these properties have values. Be careful not to
log these! The program needs to keep the value around!

=cut

sub logged_in_user ( $self ) { $self->username }
sub username ( $self )       { $self->{username} }
sub has_username ( $self )   { !! defined $self->{username} }

sub password ( $self )     { $self->{password} }
sub has_password ( $self ) { !! defined $self->{password} }

sub token ( $self )     { $self->{token} }
sub has_token ( $self ) { !! defined $self->{token} }

=item * auth_string

Returns the C<Authorization> header value, whether it's the token or Basic
authorization.

=cut

sub auth_string ( $self ) {
	if( $self->has_token )         { $self->token_auth_string }
	elsif( $self->has_basic_auth ) { $self->basic_auth_string }
	}

=item * has_basic_auth

Checks that we know the username and password.

=cut

sub has_basic_auth ( $self ) {
	$self->warnif( ! $self->has_username, "Missing username for basic authorization!" );
	$self->warnif( ! $self->has_password, "Missing password for basic authorization!" );
	$self->has_username && $self->has_password
	}

=item * token_auth_string

Returns the value for the C<Authorization> request header, using
Basic authorization. This requires username and password values.

=cut

sub basic_auth_string ( $self ) {
	my $rc = require MIME::Base64;
	return unless $self->has_basic_auth;
	'Basic ' . MIME::Base64::encode_base64(
		join( ':', $self->username, $self->password ),
		''
		);
	}

=item * token_auth_string

Returns the value for the C<Authorization> request header, using
token authorization.

=cut

sub token_auth_string ( $self ) {
	$self->warnif( ! $self->has_token, "Missing token for token authorization!" );
	return unless $self->has_token;
	'token ' . $self->token;
	}

=item * token_file

Returns the value of either the environment variable C<GITHUB_DEV_TOKEN>
or C<.github_token>. If you want some other value, I suggest a subclass
that overrides this method.

=cut

sub token_file ( $self ) { $ENV{GITHUB_DEV_TOKEN} // '.github_token' }

=item * add_token( TOKEN )

Adds the token to the object. After this, the object will try to use
the token authorization in all queries.

=cut

sub add_token ( $self, $token ) {
	chomp $token;
	unless( $token ) {
		$self->logger->error( "There's not token!" );
		return;
		}

	$self->{token} = $token;
	$self->remember_token;
	$self->add_token_auth_to_all_requests;
	bless $self, $self->authenticated_user_class;

	return $token;
	}

=item * add_token_auth_to_all_requests( TOKEN )

Installs a start event for the L<Mojo::UserAgent> to add the C<Authorization>
header. You don't need to do this yourself.

=cut

sub add_token_auth_to_all_requests ( $self ) {
	unless( $self->has_token ) {
		$self->logger->logdie( "There is no auth token, so I can't add it to every request!" );
		return 0;
		}

	$self->ua->on( start => sub {
		my( $ua, $tx ) = @_;
		$tx->req->headers->authorization( $self->token_auth_string );
		} );
	}

=item * remember_token

Put the token in a file to use later. You normally don't need to call
this yourself.

=cut

sub remember_token ( $self ) {
	unless( $self->token ) {
		$self->logger->warn( "There is no token to remember!" );
		return;
		}

	if( open my $fh, '>:utf8', $self->token_file ) {
		print $fh $self->token;
		close $fh;
		}
	else {
		$self->logger->warn( "Could not open token file! $!" );
		$self->logger->warn( "Token is " . $self->token );
		}
	}

=back

=head2 Queries

=over 4

=item * ua

Returns the L<Mojo::UserAgent> object.

=cut

sub ua ( $self ) {
	state $rc = require Mojo::UserAgent;
	state $ua = do {
		my $ua = Mojo::UserAgent->new;
		$ua->on( start => sub {
			my( $ua, $tx ) = @_;
			# https://developer.github.com/v3/#current-version
			$tx->req->headers->accept( 'application/vnd.github.v3+json' );
			});
		$ua;
	};
	$ua->transactor->name( sprintf "Ghojo %s", __PACKAGE__->VERSION );
	$ua;
	}

=item * api_base_url

The base URL for the API. By default this is C<https://api.github.com/>.

=cut

sub api_base_url ( $self ) { Mojo::URL->new( 'https://api.github.com/' ) }

=item * query_url( PATH, PARAMS_ARRAY_REF, QUERY_HASH )

I don't particularly like this, so I'm working on endpoint_to_url instead.
I don't like the sprintf-like handling. I want to start with the literal
endpoint, such as C</users/:username>.

Creates the query URL. Some of the data are in the PATH, so that's a
sprintf type string that fill in the placeholders with the values in
C<PARAMS_ARRAY_REF>. The C<QUERY_HASH> forms the query string for the URL.

	my $url = query_url( '/foo/%s/%s', [ $user, $repo ], { since => $count } );

=cut

sub query_url ( $self, $path, $params=[], $query={} ) {
	# If we ever supported Enterprise, we have to consider a different
	# way to get the base url. There could be several.
	state $api = $self->api_base_url;
	my $modified = sprintf $path, $params->@*;
	my $url = $api->clone->path( $modified )->query( $query );
	}

=item * endpoint_to_url( END_POINT, REST_PARAMS_HASH, QUERY_PARAMS_HASH )

Translates an endpoint, such as C</users/:username> to the URL to
access. The REST_PARAMS_HASH has values for the names in the enpoint (such
as C<:username> in this example). The QUERY_PARAMS_HASH hash translates into
the GET query string.

	$self->endpoint_to_url(
		'/users/:username'
		=> {  # parameters in the path
			username => 'octocat',
			}
		=> { # query_string
			foo => 'bar'
			}
		);

TODO XXX: There are a couple of complicated query setups that require
extra handling. This just squirts the hash to Mojo::URL's query.

=cut

sub endpoint_to_url ( $self, $endpoint, $rest_params = {}, $query_params = {} ) {
	state $api = $self->api_base_url;

	my $copy = $endpoint;

	foreach my $key ( keys $rest_params->%* ) {
		$copy =~ s/:$key/$rest_params->{$key}/;
		}

	if( my @missing_rest_params = $copy =~ m|/:(.*?)/|g ) {
		foreach my $param ( @missing_rest_params ) {
			$self->logger->warn( "Missing parameter [$param] for endpoint [$endpoint]" )
			}
		return;
		}

	my $url = $api->clone->path( $copy )->query( $query_params );

	return $endpoint;
	}

sub post_json( $self, $query_url, $headers = {}, $hash = {} ) {
	$self->{last_tx} = $self->ua->post( $query_url => $headers => json => $hash );
	}

sub last_tx ( $self ) { $self->{last_tx} }


# designed for responses that return everything at once (and not
# paged)

sub default_data_class ( $self ) { 'Ghojo::Data::Unspecified' }

BEGIN {
	# This stuff will help with rate limiting.
	my $query_count;
	sub increment_query_count ( $self ) { $query_count++   }
	sub get_query_count       ( $self ) { $query_count     }
	sub clear_query_count     ( $self ) { $query_count = 0 }
	};

sub single_resource ( $self, $verb, $url, %args  ) {
	state $allowed_verbs = { # with default expected http statuses
		get      => 200,
		post     => 201,
		put      => 200,
		patch    => 200,
		'delete' => 204,
		};

	# Check that we have an allowed verb. You shouldn't call this
	# directly in application code, but this check ensures that
	# $verb is something we can handle.
	$verb = lc $verb;
	return unless exists $allowed_verbs->{$verb};

	# turn every value for expected_http_status into an array. There
	# are some operations that have more than one HTTP status that
	# signifies normal operation.
	$args{expected_http_status} //= $allowed_verbs->{$verb};
	$args{expected_http_status} = [ $args{expected_http_status} ]
		unless ref $args{expected_http_status} eq ref [];

	# Before we make the query, check that we have the right scope.
	# When you create a personal access token, you can specify which
	# scopes you want. When we stored the token, we asked for the list
	# of scopes.
	#
	# There are also scopes for teams and orgs
	unless( $self->has_scopes( $args{required_scopes} ) ) {
		$self->logger->error( "This operation does not have the required scopes []" );
		return;
		}

	# XXX: Check rate status before we try this?

	my $tx = $self->ua->$verb( $url );
	$self->increment_query_count;

	my $data = $tx->res->json


	# check that status is one of the expected statuses

		# if it was the expected status, take the JSON in the
		# message body and bless it into the right class


	# if the status is not the expected status, look at the response
	# to see why it failed.

		# connection failure

		# bad request

		# rate limit
	}

sub get_single_resource ( $self, $url, %args ) {
	$self->logger->enter_sub;
	$self->single_resource( GET => $url => %args );
	}

sub post_single_resource ( $self, $url, %args ) {
	$self->logger->enter_sub;
	$self->single_resource( POST => $url => %args );
	}

sub put_single_resource ( $self, $url, %args ) {
	$self->logger->enter_sub;
	$self->single_resource( PUT => $url => %args );
	}

sub patch_single_resource ( $self, $url, %args ) {
	$self->logger->enter_sub;
	$self->single_resource( PATCH => $url => %args );
	}

sub delete_single_resource ( $self, $url, %args ) {
	$self->logger->enter_sub;
	$self->single_resource( DELETE => $url => %args );
	}


# this is blocking, but there's not another way around it
# you don't know the next one until you see the response
sub get_paged_resources ( $self, $url, %args ) {
	$self->logger->enter_sub;

	my @results;

	$args{limit}   //= 1000;
	$args{'sleep'} //=    3;

	my @queue;
	while( @results < $args{limit} and my $url = shift @queue ) {
		my $tx = $self->ua->get( $url );
		my $link_header = $self->parse_link_header( $tx );
		push @queue, $link_header->{'next'} if exists $link_header->{'next'};

		my $array = $tx->res->json;
		push @results, $array->@*;

		sleep $args{'sleep'};
		}

	Mojo::Collection->new( @results );
	}

sub set_paged_get_sleep_time ( $self, $seconds = 3 ) {
	$self->{paged_get}{'sleep'} = 0 + $seconds;
	}
sub paged_get_sleep_time ( $self ) { $self->{paged_get}{'sleep'} }

sub set_paged_get_results_limit ( $self, $count = 10_000 ) {
	$self->{paged_get}{'results_limit'} = $count;
	}
sub paged_get_results_limit ( $self ) { $self->{paged_get}{'results_limit'} }

sub paged_get ( $self, $path, $params = [], $callback=sub{ $_[0] }, $query = {} ) {
	$self->logger->trace( 'In paged_get' );
	my @results;
	my $limit = $self->paged_get_results_limit // 1_000;
	my @next = $self->query_url( $path, $params, $query);
		$self->logger->debug( "Queue is:\n\t", join "\n\t", @next );

	while( @results < $limit and my $url = shift @next ) {
		$self->logger->debug( "query_url is $url" );
		my $tx = $self->ua->get( $url );
		my $link_header = $self->parse_link_header( $tx );
		push @next, $link_header->{'next'} if exists $link_header->{'next'};

		my $array = $tx->res->json;
		foreach my $item ( $array->@* ) {
			push @results, $callback->( $item );
			}
		sleep $self->paged_get_sleep_time;
		}

	Mojo::Collection->new( @results );
	}

# <https://api.github.com/repositories?since=367>; rel="next", <https://api.github.com/repositories{?since}>; rel="first"';
sub parse_link_header ( $self, $tx ) {
	my $link_header = $tx->res->headers->header( 'Link' );
	$self->logger->trace( "Link header is <$link_header>" );
	return {} unless $link_header;

	my @parts = $link_header =~ m{
		<(.*?)>; \s+ rel="(.*?)"
		}xg;

	my %hash = reverse @parts;
	return \%hash;
	}

=back

=head2 Authorizations

This section of the GitHub API allows you to create Personal Access Tokens.

=over 4

=item * authorizations

=cut

sub authorizations ( $self ) {
	state $query_url = $self->query_url( "/authorizations" );
	}

sub get_authorization ( $self ) {
	state $query_url = $self->query_url( "/authorizations/%s" );
	}

sub authorization ( $self, $id ) {
	state $query_url = $self->query_url( "/authorizations/%s" );
	}

=item * is_valid_scope( SCOPE )

Returns a list of all valid scopes.

https://developer.github.com/v3/oauth/#scopes

=cut

sub valid_scopes ( $self ) {
	state $scopes = [ qw(
		user
		user:email
		user:follow
		public_repo
		repo
		repo_deployment
		repo:status
		delete_repo
		notifications
		gist
		read:repo_hook
		write:repo_hook
		admin:repo_hook
		admin:org_hook
		read:org
		write:org
		admin:org
		read:public_key
		write:public_key
		admin:public_key
		read:gpg_key
		write:gpg_key
		admin:gpg_key
		) ];
	}

=item * is_valid_scope( SCOPE )

Returns true if SCOPE is a valid authorization scope.

=cut

sub is_valid_scope ( $self, $scope ) {
	state $scopes = { map { lc $_, undef } $self->valid_scopes };
	exists $scopes->{ lc $scope };
	}

=item * create_authorization

Creates a "Personal Access Token" for the logged in user.

https://developer.github.com/v3/oauth_authorizations/#create-a-new-authorization

=cut

sub create_authorization ( $self, $hash = {} ) {
	state $query_url = $self->query_url( "/authorizations" );
	state $allowed   = [ qw(scopes note note_url client_id client_secret fingerprint) ];
	state $required  = [ qw(note) ];

	$hash->{scopes} //= ['user', 'public_repo', 'repo', 'gist'];
	$hash->{note}   //= 'test purpose ' . time;
	$self->post_json( $query_url, { 'Authorization' => $self->basic_auth_string }, $hash );

	unless( $self->last_tx->success ) {
		my $err = $self->last_tx->error;
		$self->logger->warn( "create_authorizaton failed!" );
		$self->warnif( $err->{code}, "$err->{code} response: $err->{message}" );
		return;
		}

	return unless $self->add_token( $self->last_tx->res->json->{token} );

	$self->token;
	}

sub update_authorization ( $self ) {
	state $query_url = $self->query_url( "/authorizations/%s" );
	url => "/authorizations/%s", method => "PATCH", args => 1
	}

sub delete_authorization ( $self ) {
	state $query_url = $self->query_url( sprintf "/authorizations/%s",  );
	url => "/authorizations/%s", method => "DELETE", check_status => 204
	}

=back

=head2 Labels

    # http://developer.github.com/v3/issues/labels/
    labels => { url => "/repos/%s/%s/labels" },
    label  => { url => "/repos/%s/%s/labels/%s" },
    create_label => { url => "/repos/%s/%s/labels", method => 'POST', args => 1 },
    update_label => { url => "/repos/%s/%s/labels/%s", method => 'PATCH', args => 1 },
    delete_label => { url => "/repos/%s/%s/labels/%s", method => 'DELETE', check_status => 204 },
    issue_labels => { url => "/repos/%s/%s/issues/%s/labels" },
    create_issue_label  => { url => "/repos/%s/%s/issues/%s/labels", method => 'POST', args => 1 },
    delete_issue_label  => { url => "/repos/%s/%s/issues/%s/labels/%s", method => 'DELETE', check_status => 204 },
    replace_issue_label => { url => "/repos/%s/%s/issues/%s/labels", method => 'PUT', args => 1 },
    delete_issue_labels => { url => "/repos/%s/%s/issues/%s/labels", method => 'DELETE', check_status => 204 },
    milestone_labels => { url => "/repos/%s/%s/milestones/%s/labels" },

=over 4

=cut

=item * labels( USER, REPO )

Get the information for all the labels of a repo.

Returns a L<Mojo::Collection> object with the hashrefs representing
labels:

	{
	'color' => 'd4c5f9',
	'url' => 'https://api.github.com/repos/briandfoy/test-file/labels/Perl%20Workaround',
	'name' => 'Perl Workaround'
	}

Implements C</repos/:owner/:repo/labels>.

=cut

sub labels ( $self, $owner, $repo ) {
	my $params = [ $owner, $repo ];
	my $url = $self->query_url( "/repos/%s/%s/labels", $params );
	$self->logger->trace( "Query URL is $url" );
	my $tx = $self->ua->get( $url );
	Mojo::Collection->new( $tx->res->json->@* );
	}

=item * get_label( USER, REPO, LABEL )

Get the information for a particular label. It returns a hashref:

	{
	'color' => '1d76db',
	'url' => 'https://api.github.com/repos/briandfoy/test-file/labels/Win32',
	'name' => 'Win32'
	}

Implements C</repos/:owner/:repo/labels/:name>.

=cut

sub get_label ( $self, $user, $repo, $name ) {
	state $expected_status = 200;
	my $params = [ $user, $repo, $name ];
	my $url = $self->query_url( "/repos/%s/%s/labels/%s", $params );
	$self->logger->trace( "Query URL is $url" );

	my $tx = $self->ua->get( $url );
	unless( $tx->code eq $expected_status ) {
		$self->logger->error( sprintf "get_label returned status %s but expected %s", $tx->code, $expected_status );
		$self->logger->debug( "get_label response for [ $user, $repo, $name ] was\n", $tx->res->body );
		return;
		}

	$tx->res->json;
	}

=item * create_label

Create a new label.

Query parameters

	name	string	(Required) The name of the label.
	color	string	(Required) A 6 character RGB color
	                Default is FF0000

Implements C<POST /repos/:owner/:repo/labels>.

=cut

sub create_label ( $self, $owner, $repo, $name, $color = 'FF0000' ) {
	state $expected_status = 201;
	my $params             = [ $owner, $repo ];

	$color =~ s/\A#//;

	my $query = {
		name  => $name,
		color => $color,
		};
	my $url = $self->query_url( "/repos/%s/%s/labels", $params, $query );

	$self->logger->trace( "Query URL is $url" );
	my $tx = $self->ua->post( $url => json => $query );
	my $code = $tx->res->code;

	unless( $code == $expected_status ) {
		my $body = $tx->res->body;
		$self->logger->error( "create_label did not return a $expected_status: $body" );
		return 0;
		}

	return 1;
	}

=item * update_label( OWNER, REPO, NAME, NEW_NAME, NEW_COLOR )

PATCH /repos/:owner/:repo/labels/:name

JSON parameters

	name	string	The name of the label.
	color	string	A 6 character hex code, without the leading #, identifying the color.

Response Status: 200 OK

=cut

sub update_label ( $self, $owner, $repo, $name, $new_name, $color ) {
	state $expected_status = 200;
	my $params             = [ $owner, $repo, $name ];

	$color =~ s/\A#//;

	my $query = {};

	$query->{name}  = $new_name if defined $new_name;
	$query->{color} = $color    if defined $color;

	my $url = $self->query_url( "/repos/%s/%s/labels/%s", $params );

	$self->logger->trace( "update_label: URL is $url" );
	my $tx = $self->ua->patch( $url => json => $query );
	my $code = $tx->res->code;

	unless( $code == $expected_status ) {
		my $body = $tx->res->body;
		$self->logger->error( "create_label did not return a $expected_status: $body" );
		return 0;
		}

	return 1;
	}

=item * delete_label( OWNER, REPO, $NAME )

DELETE /repos/:owner/:repo/labels/:name

Status: 204 No Content

=cut

sub delete_label ( $self, $owner, $repo, $name ) {
	state $expected_status = 204;
	my $params             = [ $owner, $repo, $name ];

	my $url = $self->query_url( "/repos/%s/%s/labels/%s", $params );

	$self->logger->trace( "delete_label: URL is $url" );
	my $tx = $self->ua->delete( $url );
	my $code = $tx->res->code;

	unless( $code == $expected_status ) {
		my $body = $tx->res->body;
		$self->logger->error( "create_label did not return a $expected_status: $body" );
		return 0;
		}

	return 1;
	}


=item * get_labels_for_issue( OWNER, REPO, ISSUE_NUMBER, CALLBACK )

GET /repos/:owner/:repo/issues/:number/labels

Response
Status: 200 OK
Link: <https://api.github.com/resource?page=2>; rel="next",
      <https://api.github.com/resource?page=5>; rel="last"

[
  {
    "url": "https://api.github.com/repos/octocat/Hello-World/labels/bug",
    "name": "bug",
    "color": "f29513"
  }
]

=cut

sub get_labels_for_issue ( $self, $owner, $repo, $number, $callback = sub { $_[0] } ) {
	state $expected_status = 200;
	my $params             = [ $owner, $repo, $number ];

	my $results = $self->paged_get(
		"/repos/%s/%s/issues/%d/labels",
		[ $owner, $repo, $number ],
		$callback,
		{}
		);
	}


=item * get_labels_for_all_issus_in_milestone

GET /repos/:owner/:repo/milestones/:number/labels
Response
Status: 200 OK
Link: <https://api.github.com/resource?page=2>; rel="next",
      <https://api.github.com/resource?page=5>; rel="last"
[
  {
    "url": "https://api.github.com/repos/octocat/Hello-World/labels/bug",
    "name": "bug",
    "color": "f29513"
  }
]

=cut

sub get_labels_for_all_issus_in_milestone ( $self, $owner, $repo, $name ) {
	state $expected_status = 200;
	my $params             = [ $owner, $repo, $name ];


	}


=item * add_labels_to_issue( OWNER, REPO, NUMBER, @LABEL_NAMES )

The NUMBER is the issue number as you see it in the website. It is not
the ID number of the issue.

POST /repos/:owner/:repo/issues/:number/labels

Input

	[
	  "Label1",
	  "Label2"
	]

Response

Status: 200 OK

	[
	  {
		"url": "https://api.github.com/repos/octocat/Hello-World/labels/bug",
		"name": "bug",
		"color": "f29513"
	  }
	]

=cut

sub add_labels_to_issue ( $self, $owner, $repo, $number, @names ) {
	state $expected_status = 200;
	my $params             = [ $owner, $repo, $number ];

	my $url = $self->query_url( "/repos/%s/%s/issues/%s/labels", $params );

	$self->logger->trace( "add_labels_to_issue: URL is $url" );
	my $tx = $self->ua->post( $url => json => \@names );
	my $code = $tx->res->code;

	unless( $code == $expected_status ) {
		my $body = $tx->res->body;
		$self->logger->error( "add_labels_to_issue did not return $expected_status: $body" );
		return 0;
		}

	return 1;
	}


=item * remove_label_from_issue

DELETE /repos/:owner/:repo/issues/:number/labels/:name
Response
Status: 204 No Content

=cut

sub remove_label_from_issue ( $self, $owner, $repo, $name ) {
	state $expected_status = 204;
	my $params             = [ $owner, $repo, $name ];


	}


=item * remove_all_labels_from_issue

DELETE /repos/:owner/:repo/issues/:number/labels
Response
Status: 204 No Content

=cut

sub remove_all_labels_from_issue ( $self, $owner, $repo, $name ) {
	state $expected_status = 204;
	my $params             = [ $owner, $repo, $name ];


	}


=item * replace_all_labels_for_issue

PUT /repos/:owner/:repo/issues/:number/labels
Input
[
  "Label1",
  "Label2"
]
Sending an empty array ([]) will remove all Labels from the Issue.

Response
Status: 200 OK
[
  {
    "url": "https://api.github.com/repos/octocat/Hello-World/labels/bug",
    "name": "bug",
    "color": "f29513"
  }
]

=cut

sub replace_all_labels_for_issue ( $self, $owner, $repo, $name ) {
	state $expected_status = 200;
	my $params             = [ $owner, $repo, $name ];


	}



=back

=head2 Issues

=over 4

=item * issues( USER, REPO, CALLBACK, HASHREF )

=item * all_issues( USER, REPO, CALLBACK, HASHREF )

=item * open_issues( USER, REPO, CALLBACK, HASHREF )

=item * closed_issues( USER, REPO, CALLBACK, HASHREF )

Get the information for all the labels of a repo.

The keys of the HASHREF can be:

	milestone   integer     If an integer is passed, it should
	            or string   refer to a milestone by its number field.
	                        If the string * is passed, issues
	                        with any milestone are accepted.
	                        If the string none is passed, issues
	                        without milestones are returned.

	state       string      Indicates the state of the issues
	                        to return. Can be either open, closed,
	                        or all. Default: open

	assignee    string      Can be the name of a user. Pass in
	                        none for issues with no assigned user,
	                        and * for issues assigned to any user.

	creator     string      The user who created the issue.

	mentioned   string      A user who's mentioned in the issue.

	labels      string      A list of comma separated label names.
	                        Example: bug,ui,@high

	sort        string      What to sort results by. Can be either created,
	                        updated, comments. Default: created

	direction   string      The direction of the sort. Can be either
	                        asc or desc. Default: desc

	since       string      Only issues updated at or after this time
	                        are returned. This is a timestamp in ISO
	                        8601 format: YYYY-MM-DDTHH:MM:SSZ.

=cut

sub issues ( $self, $owner, $repo, $callback = sub { } , $query = { 'state' => 'open' } ) {
	state $expected_status = 200;

	my $url = $self->query_url( "/repos/%s/%s/issues", [ $owner, $repo ], $query );
	$self->logger->trace( "Query URL is $url" );
	my $results = $self->paged_get(
		"/repos/%s/%s/issues",
		[ $owner, $repo ],
		$callback,
		$query
		);
	}

sub all_issues ( $self, $user, $repo, $callback = sub { $_[0] }, $query = {} ) {
	$query->{'state'} = 'all';
	$self->issues( $user, $repo, $callback, $query );
	}

sub open_issues ( $self, $user, $repo, $callback = sub { $_[0] }, $query = {} ) {
	$query->{'state'} = 'open';
	$self->issues( $user, $repo, $callback, $query );
	}

sub closed_issues ( $self, $user, $repo, $callback = sub { $_[0] }, $query = {} ) {
	$query->{'state'} = 'closed';
	$self->issues( $user, $repo, $callback, $query );
	}

=item * issue( USER, REPO, NUMBER )

Get the information for a particular label.

It returns a hashref:

	{
	'color' => '1d76db',
	'url' => 'https://api.github.com/repos/briandfoy/test-file/labels/Win32',
	'name' => 'Win32'
	}

This implements C<GET /repos/:owner/:repo/labels/:name> from L<http://developer.github.com/v3/issues/labels/>.

=cut

sub issue ( $self, $user, $repo, $number ) {
	my $query_url = $self->query_url( "/repos/%s/%s/issues/%d", $user, $repo, $number );
	$self->logger->trace( "Query URL is $query_url" );
	my $tx = $self->ua->get( $query_url );
	$tx->res->json;
	}

=back

=head2 Repositories

=over 4

=item * repos

GET /user/repos

	visibility      string
	    Can be one of all, public, or private.
	    Default: all

	affiliation     string	Comma-separated list of values. Can include:
	    * owner
	    * collaborator
	    * organization_member
		Default: owner,collaborator,organization_member

	type            string
		Can be one of all, owner, public, private, member.
		Default: all

	    Will cause a 422 error if used in the same request as
	    visibility or affiliation.

	sort            string
		Can be one of created, updated, pushed, full_name.
		Default: full_name

	direction       string
		Can be one of asc or desc.
		Default: when using full_name: asc; otherwise desc

=cut

sub repos ( $self, $callback = sub {}, $query = {} ) {
	$self->logger->trace( 'In repos' );
	my $perl = $self->paged_get( '/user/repos', [], $callback, $query );
	}


=item * get_repo ( OWNER, REPO )

GET /repos/:owner/:repo

The parent and source objects are present when the repository is a
fork. parent is the repository this repository was forked from, source
is the ultimate source for the network.

=cut

sub get_repo ( $self, $owner, $repo ) {
	state $expected_status = 200;

	my $url = $self->query_url( '/repos/%s/%s', [ $owner, $repo ] );
	my $tx  = $self->ua->get( $url );

	unless( $tx->res->code == $expected_status ) {
		my $json = $tx->res->json;
		if( $json->{message} eq 'Not Found' ) {
			$self->logger->error( "get_repo: repo $owner/$repo was not found" );
			}
		else {
			$self->logger->error( "get_repo: unspecified error looking for $owner/$repo. Code " . $tx->res->code );
			$self->logger->debug( "get_repo: " . $tx->res->body );
			}
		return;
		}

	my $perl = $tx->res->json;
	}

=item * repos_by_username( USERNAME )

GET /users/:username/repos

type	string	Can be one of all, owner, member. Default: owner
sort	string	Can be one of created, updated, pushed, full_name. Default: full_name
direction	string	Can be one of asc or desc. Default: when using full_name: asc, otherwise desc

=cut

sub repos_by_username( $self, $username ) {
	$self->paged_get( '', [ $username ] );

	}

=item * repos_by_organization

GET /orgs/:org/repos
type	string	Can be one of all, public, private, forks, sources, member. Default: all

=cut

sub repos_by_organization( $self, $organization ) {


	}

=item * all_public_repos( CALLBACK, QUERY_HASH )

GET /repositories

since	string	The integer ID of the last Repository that you've seen.

=cut

sub all_public_repos ( $self, $callback = sub {}, $query = {} ) {
	my $perl = $self->paged_get( '/repositories', [], $callback, $query );
	}

=item * edit_repo

	PATCH /repos/:owner/:repo

=cut

sub edit_repo( $self, $owner, $repo, $hash = {} ) {

	}

=item * list_repo_contributors( OWNER, REPO )

GET /repos/:owner/:repo/contributors

anon	string	Set to 1 or true to include anonymous contributors in results.

=cut

sub get_repo_contributors ( $self, $owner, $repo ) {


	}

=item * get_repo_languages

GET /repos/:owner/:repo/languages

=cut

sub get_repo_languages ( $self, $owner, $repo ) {


	}

=item * get_repo_teams

GET /repos/:owner/:repo/teams

=cut

sub get_repo_teams ( $self, $owner, $repo ) {


	}

=item * get_repo_tags

	GET /repos/:owner/:repo/tags


=cut

sub get_repo_tags ( $self, $owner, $repo ) {


	}

=item * delete_repo

DELETE /repos/:owner/:repo

Deleting a repository requires admin access. If OAuth is used, the delete_repo scope is required.

=cut

sub delete_repo ( $owner, $repo ) {

	}

=back

=head2 Organizations

=over 4

=back

=head2 Users

The Users portion of the API is implemented in L<Ghojo::Endpoint::Users>.

=head1 SOURCE AVAILABILITY

This module is in Github:

	git://github.com/briandfoy/ghojo.git

=head1 AUTHOR

brian d foy, C<< <bdfoy@cpan.org> >>

=head1 COPYRIGHT AND LICENSE

Copyright © 2016, brian d foy <bdfoy@cpan.org>. All rights reserved.

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__
