# HTTP::Message is optional: hide it, and check hashref callers never need it
use 5.042;
BEGIN {
  unshift @INC, sub ($hook, $file) {
    die "HTTP::Message is hidden for this test\n" if $file =~ m{^HTTP/(?:Message|Request|Response|Headers)(?:/|\.pm$)};
    return;
  };
}
use Test2::V0 -no_srand => 1;
use lib 't/lib';
use OpenAPI::Humbug;
use FakeTransport;

ok !eval { require HTTP::Request; 1 }, 'HTTP::Message cannot be loaded';

my($humbug) = fake_client();
ok $humbug->validate(
  request  => { method => 'GET', url => 'https://api.example.test/pets/1' },
  response => { status => 200, body => '{}' },
)->{valid}, 'hashref request and response';

my $error = dies { $humbug->validate(request => bless({}, 'Some::Thing')) };
is [ $error->kind, $error->code ], [ 'argument', 'client.argument' ], 'other objects are an argument error';

$error = dies { $humbug->validate(response => { status => 200 }) };
is [ $error->kind, $error->code ], [ 'argument', 'client.argument' ], 'hashref response alone is still an error';

is [ grep { m{^HTTP/(?:Message|Request|Response|Headers)} || m{^OpenAPI/Humbug/Adapter/} } sort keys %INC ], [],
  'no HTTP::Message and no adapter loaded';

$humbug->close;

done_testing;
