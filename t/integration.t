use Test2::V0 -no_srand => 1;
use 5.042;
use OpenAPI::Humbug;

# Runs against a real humbug; see "TESTING" in OpenAPI::Humbug.
#   OPENAPI_HUMBUG_EXECUTABLE=/path/to/humbug prove -lv t/integration.t

my $executable = $ENV{OPENAPI_HUMBUG_EXECUTABLE};
skip_all 'set OPENAPI_HUMBUG_EXECUTABLE to a humbug executable to run these tests' unless $executable;

my $base = 'https://api.example.test';
my @json = (['Content-Type', 'application/json']);

sub codes ($side) { [ sort map { $_->{code} } $side->{diagnostics}->@* ] }

my $humbug = OpenAPI::Humbug->new(spec => 'corpus/pets.yaml', executable => $executable);
my $pid = $humbug->{transport}->pid;

subtest 'initialize' => sub {
  is $humbug->specification, hash { field openapi_version => '3.1.0'; field title => 'Pets'; etc }, 'specification';
  is $humbug->limits, D(), 'limits reported';
  note "implementation: @{[ $humbug->implementation->{name} ]} @{[ $humbug->implementation->{version} ]}"
    if $humbug->implementation;
};

subtest 'valid request' => sub {
  my $result = $humbug->validate(request => {
    method  => 'POST',
    url     => "$base/pets",
    headers => [@json, ['X-Request-Id', 'abc123']],
    body    => '{"name":"Rex","age":3}',
  });
  is $result->{valid}, T(), 'valid';
  is $result->{request}{status}, 'valid', 'request side valid';
  is $result->{response}{status}, 'skipped', 'response skipped';
};

subtest 'invalid request' => sub {
  my $result = $humbug->validate(request => {
    method  => 'POST',
    url     => "$base/pets",
    headers => [@json, ['X-Request-Id', 'abc123']],
    body    => '{"name":"Rex","age":-1}',
  });
  is $result->{valid}, F(), 'not valid';
  is $result->{complete}, T(), 'complete';
  is $result->{has_violations}, T(), 'has violations';
  is $result->{request}{status}, 'invalid', 'request side invalid';
  like codes($result->{request}), bag { item 'schema.minimum'; etc }, 'minimum diagnostic';
  my($d) = grep { $_->{code} eq 'schema.minimum' } $result->{request}{diagnostics}->@*;
  is $d->{instance}{pointer}, '/age', 'pointer';
  is $d->{severity}, 'error', 'severity';
};

subtest 'absent and empty bodies differ' => sub {
  my %request = (method => 'POST', url => "$base/pets", headers => [@json, ['X-Request-Id', 'abc123']]);
  like codes($humbug->validate(request => {%request})->{request}),             bag { item 'body.required'; etc }, 'absent';
  like codes($humbug->validate(request => {%request, body => ''})->{request}), bag { item 'body.decode'; etc },   'empty';
};

subtest 'request and response' => sub {
  my $result = $humbug->validate(
    request  => { method => 'GET', url => "$base/pets/7" },
    response => { status => 200, headers => [@json], body => '{"id":7}' },
  );
  is $result->{request}{status}, 'valid', 'request valid';
  is $result->{response}{status}, 'invalid', 'response invalid';
  like codes($result->{response}), bag { item 'schema.required'; etc }, 'missing name';
  is $result->{valid}, F(), 'transaction not valid';
};

subtest 'response only via selector' => sub {
  my $result = $humbug->validate(
    request  => { method => 'GET', url => "$base/pets/not-a-number" },
    response => { status => 200, headers => [@json], body => '{"id":7,"name":"Rex"}' },
    validate => { request => 0, response => 1 },
  );
  is $result->{request}{status}, 'skipped', 'request skipped';
  is $result->{response}{status}, 'valid', 'response valid';
  is $result->{valid}, T(), 'transaction valid over the checked side';
};

subtest 'warning only' => sub {
  my $result = $humbug->validate(request => {
    method  => 'POST',
    url     => "$base/pets",
    headers => [@json, ['X-Request-Id', 'abc123'], ['X-Request-Id', 'def456']],
    body    => '{"name":"Rex"}',
  });
  my($warning) = grep { $_->{code} eq 'header.repeated' } $result->{request}{diagnostics}->@*;
  ok $warning, 'header.repeated reported';
  is $warning->{severity}, 'warning', 'as a warning';
  is $result->{valid}, T(), 'still valid';
  is $result->{has_violations}, F(), 'no violations';
};

subtest 'binary header values reach the sidecar' => sub {
  my $error = dies {
    $humbug->validate(request => { method => 'GET', url => "$base/pets/1", headers => [['X-Bad', "a\x00b"]] });
  };
  is [ $error->kind, $error->code ], [ 'sidecar', 'validator.unsupported_input' ], 'NUL byte in a value is refused by the sidecar';
  ok $humbug->validate(request => { method => 'GET', url => "$base/pets/1", headers => [['X-Latin', "caf\xE9"]] })->{valid},
    'non-UTF-8 value accepted';
};

subtest 'sidecar error keeps the client usable' => sub {
  my $error = dies {
    $humbug->validate(request => { method => 'GET', url => "$base/pets/1" }, validate => { request => 0 });
  };
  is [ $error->kind, $error->code ], [ 'sidecar', 'protocol.invalid_message' ], 'both checks disabled';
  ok $humbug->validate(request => { method => 'GET', url => "$base/pets/1" })->{valid}, 'still usable';
};

subtest 'same child throughout' => sub {
  is $humbug->{transport}->pid, $pid, 'one process';
  ok $humbug->close, 'clean shutdown';
  ok !kill(0, $pid), 'reaped';
};

subtest 'incomplete' => sub {
  my $small = OpenAPI::Humbug->new(
    spec       => 'corpus/pets.yaml',
    executable => $executable,
    args       => ['-max-body-bytes', 8],
  );
  is $small->limits->{max_body_bytes}, 8, 'limit set by argument';
  my $result = $small->validate(request => {
    method  => 'POST',
    url     => "$base/pets",
    headers => [@json, ['X-Request-Id', 'abc123']],
    body    => '{"name":"Rex"}',
  });
  is $result->{complete}, F(), 'not complete';
  is $result->{valid}, F(), 'not valid';
  is $result->{request}{status}, 'incomplete', 'request side incomplete';
  my($d) = grep { $_->{code} eq 'validation.incomplete' } $result->{request}{diagnostics}->@*;
  is $d->{reason}, 'body.too_large', 'reason';
  ok $small->close, 'close';
};

subtest 'invalid specification' => sub {
  my $error = dies { OpenAPI::Humbug->new(spec => 'corpus/unsupported.yaml', executable => $executable) };
  is [ $error->kind, $error->code ], [ 'sidecar', 'spec.unsupported_version' ], 'unsupported version';
  ok length $error->message, 'with a message';

  $error = dies { OpenAPI::Humbug->new(spec => 'corpus/does-not-exist.yaml', executable => $executable) };
  is [ $error->kind, $error->code ], [ 'sidecar', 'spec.invalid' ], 'missing file';
};

done_testing;
