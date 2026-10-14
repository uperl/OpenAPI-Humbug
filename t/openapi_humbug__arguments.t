use Test2::V0 -no_srand => 1;
use 5.042;
use lib 't/lib';
use OpenAPI::Humbug;
use FakeHumbug;

sub argument_error ($code, $name) {
  my $error = dies { $code->() };
  isa_ok $error, 'OpenAPI::Humbug::Error';
  is [ $error->kind, $error->code ], [ 'argument', 'client.argument' ], $name
    or diag $error;
}

subtest 'new' => sub {
  argument_error sub { OpenAPI::Humbug->new },                                  'spec required';
  argument_error sub { OpenAPI::Humbug->new(spec => '') },                      'empty spec';
  argument_error sub { OpenAPI::Humbug->new(spec => ['x']) },                   'spec reference';
  argument_error sub { OpenAPI::Humbug->new(spec => 'x', bogus => 1) },         'unknown option';
  argument_error sub { OpenAPI::Humbug->new(spec => 'x', args => 'x') },        'args not an array';
  argument_error sub { OpenAPI::Humbug->new(spec => 'x', args => [undef]) },    'args with undef';
  argument_error sub { OpenAPI::Humbug->new(spec => 'x', timeout => 0) },       'zero timeout';
  argument_error sub { OpenAPI::Humbug->new(spec => 'x', timeout => 'soon') },  'bad timeout';
  argument_error sub { OpenAPI::Humbug->new(spec => 'x', executable => '') },   'empty executable';
};

my $humbug = fake_humbug();
my %get = (method => 'GET', url => 'https://x/');

my @bad = (
  [ 'no request',            [] ],
  [ 'request not a hash',    [ request => [] ] ],
  [ 'unknown argument',      [ request => {%get}, extra => 1 ] ],
  [ 'unknown request key',   [ request => {%get, body_base64 => 'AA=='} ] ],
  [ 'missing method',        [ request => { url => 'https://x/' } ] ],
  [ 'empty method',          [ request => { %get, method => '' } ] ],
  [ 'missing url',           [ request => { method => 'GET' } ] ],
  [ 'url reference',         [ request => { %get, url => \'x' } ] ],
  [ 'headers hash',          [ request => { %get, headers => { 'Content-Type' => 'text/plain' } } ] ],
  [ 'header not an array',   [ request => { %get, headers => ['Content-Type: text/plain'] } ] ],
  [ 'header one element',    [ request => { %get, headers => [['X-A']] } ] ],
  [ 'header three elements', [ request => { %get, headers => [['X-A', 'v', 1]] } ] ],
  [ 'header undef value',    [ request => { %get, headers => [['X-A', undef]] } ] ],
  [ 'header undef name',     [ request => { %get, headers => [[undef, 'v']] } ] ],
  [ 'header empty name',     [ request => { %get, headers => [['', 'v']] } ] ],
  [ 'header ref value',      [ request => { %get, headers => [['X-A', ['v']]] } ] ],
  [ 'header wide value',     [ request => { %get, headers => [['X-A', "\x{263A}"]] } ] ],
  [ 'body hash',             [ request => { %get, body => { a => 1 } } ] ],
  [ 'body array',            [ request => { %get, body => [1] } ] ],
  [ 'body wide characters',  [ request => { %get, body => "\x{263A}" } ] ],
  [ 'response not a hash',   [ request => {%get}, response => 200 ] ],
  [ 'response no status',    [ request => {%get}, response => {} ] ],
  [ 'response bad status',   [ request => {%get}, response => { status => 'OK' } ] ],
  [ 'response status 99',    [ request => {%get}, response => { status => 99 } ] ],
  [ 'response status 600',   [ request => {%get}, response => { status => 600 } ] ],
  [ 'response status 2e2',   [ request => {%get}, response => { status => '2e2' } ] ],
  [ 'response unknown key',  [ request => {%get}, response => { status => 200, reason => 'OK' } ] ],
  [ 'response headers hash', [ request => {%get}, response => { status => 200, headers => {} } ] ],
  [ 'validate not a hash',   [ request => {%get}, validate => 1 ] ],
  [ 'validate unknown key',  [ request => {%get}, validate => { body => 1 } ] ],
  [ 'validate reference',    [ request => {%get}, validate => { request => [] } ] ],
);

for my $case (@bad) {
  my($name, $args) = @$case;
  argument_error sub { $humbug->validate(@$args) }, $name;
}

my(undef, $command) = wire_command($humbug->validate(request => {%get}));
is $command->{id}, 2, 'nothing was sent for the rejected calls';

ok $humbug->close, 'close';

done_testing;
