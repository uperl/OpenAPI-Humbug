use Test2::V0 -no_srand => 1;
use 5.042;
use OpenAPI::Humbug::Error;

my $error = dies {
  OpenAPI::Humbug::Error->throw(kind => 'sidecar', code => 'spec.invalid', message => 'cannot read', error => { code => 'spec.invalid', message => 'cannot read' });
};
my $line = __LINE__ - 2;

isa_ok $error, 'OpenAPI::Humbug::Error';
is $error->kind, 'sidecar', 'kind';
is $error->code, 'spec.invalid', 'code';
is $error->message, 'cannot read', 'message';
is $error->error, { code => 'spec.invalid', message => 'cannot read' }, 'error';
is $error->stderr, U(), 'stderr';
is $error->file, __FILE__, 'file';
is $error->line, $line, 'line';
is "$error", "humbug sidecar error (spec.invalid): cannot read at @{[ __FILE__ ]} line $line.\n", 'stringifies';
ok !!$error, 'true in boolean context';

done_testing;
