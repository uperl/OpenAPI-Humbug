# Mojolicious is optional: hide it, and check hashref callers never need it
use 5.042;
BEGIN {
  unshift @INC, sub ($hook, $file) {
    die "Mojolicious is hidden for this test\n" if $file =~ m{^Mojo(?:licious)?(?:/|\.pm$)};
    return;
  };
}
use Test2::V0 -no_srand => 1;
use 5.042;
use lib 't/lib';
use OpenAPI::Humbug;
use FakeTransport;

ok !eval { require Mojo::Base; 1 }, 'Mojolicious cannot be loaded';

my($humbug) = fake_client();
ok $humbug->validate(
  request  => { method => 'GET', url => 'https://api.example.test/pets/1' },
  response => { status => 200, body => '{}' },
)->{valid}, 'hashref request and response';

my $error = dies { $humbug->validate(request => bless({}, 'Some::Thing')) };
is [ $error->kind, $error->code ], [ 'argument', 'client.argument' ], 'other objects are an argument error';

is [ grep { m{^(?:Mojo|Mojolicious)[/.]} || m{^OpenAPI/Humbug/Adapter/} } sort keys %INC ], [], 'no Mojo and no adapter loaded';

$humbug->close;

done_testing;
