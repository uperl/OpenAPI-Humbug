use Test2::V0 -no_srand => 1;
use 5.042;
use lib 't/lib';
use OpenAPI::Humbug;
use FakeTransport;

my %get = (method => 'GET', url => 'https://api.example.test/pets/1');

# a validate reply that breaks the protocol is a protocol failure that ends the client
sub bad_reply ($name, $reply, $code) {
  subtest $name => sub {
    my($humbug, $transport) = fake_client(responder => sub ($command, $line) {
      return $command->{type} eq 'validate' ? $reply->($command->{id}) : undef;
    });
    my $error = dies { $humbug->validate(request => {%get}) };
    isa_ok $error, 'OpenAPI::Humbug::Error';
    is [ $error->kind, $error->code ], [ 'protocol', $code ], 'kind and code' or diag $error;
    is $error->stderr, 'fake stderr', 'stderr from the transport';
    ok $transport->aborted, 'transport aborted';
    is dies { $humbug->validate(request => {%get}) }->kind, 'closed', 'client unusable afterwards';
    ok lives { $humbug->close }, 'close does not throw';
  };
}

my $result = { valid => true };

bad_reply 'malformed JSON',         sub ($id) { "{not json\n" },                                   'client.malformed_reply';
bad_reply 'not an object',          sub ($id) { "[1,2]\n" },                                       'client.malformed_reply';
bad_reply 'mismatched id',          sub ($id) { { id => $id + 1, type => 'result', result => $result } }, 'client.id_mismatch';
bad_reply 'string id',              sub ($id) { { id => "x$id", type => 'result', result => $result } },  'client.id_mismatch';
bad_reply 'missing id',             sub ($id) { { type => 'result', result => $result } },                'client.id_mismatch';
bad_reply 'null id on a result',    sub ($id) { { id => undef, type => 'result', result => $result } },   'client.id_mismatch';
bad_reply 'no type',                sub ($id) { { id => $id, result => $result } },                       'client.unexpected_reply';
bad_reply 'unexpected type',        sub ($id) { { id => $id, type => 'banana', result => $result } },     'client.unexpected_reply';
bad_reply 'result without result',  sub ($id) { { id => $id, type => 'result' } },                        'client.unexpected_reply';
bad_reply 'result not an object',   sub ($id) { { id => $id, type => 'result', result => [] } },          'client.unexpected_reply';
bad_reply 'error without code',     sub ($id) { { id => $id, type => 'error', error => { message => 'x' } } }, 'client.unexpected_reply';
bad_reply 'error without message',  sub ($id) { { id => $id, type => 'error', error => { code => 'x' } } },    'client.unexpected_reply';

subtest 'sidecar error keeps the client usable' => sub {
  my($humbug, $transport) = fake_client(responder => sub ($command, $line) {
    return undef unless $command->{type} eq 'validate' && $command->{params}{request}{url} eq 'error';
    return { id => $command->{id}, type => 'error', error => { code => 'validator.unsupported_input', message => 'no', extra => [1] } };
  });
  my $error = dies { $humbug->validate(request => { %get, url => 'error' }) };
  is [ $error->kind, $error->code, $error->message ], [ 'sidecar', 'validator.unsupported_input', 'no' ], 'sidecar error';
  is $error->error, { code => 'validator.unsupported_input', message => 'no', extra => [1] }, 'whole error object kept';
  ok !$transport->aborted, 'transport not aborted';
  ok $humbug->validate(request => {%get})->{valid}, 'still usable';
  ok $humbug->close, 'close';
};

subtest 'null id on an error answers the command in flight' => sub {
  my($humbug) = fake_client(responder => sub ($command, $line) {
    return undef unless $command->{type} eq 'validate' && $command->{params}{request}{url} eq 'long';
    return { id => undef, type => 'error', error => { code => 'protocol.line_too_long', message => 'too long' } };
  });
  my $error = dies { $humbug->validate(request => { %get, url => 'long' }) };
  is [ $error->kind, $error->code ], [ 'sidecar', 'protocol.line_too_long' ], 'sidecar error';
  ok $humbug->validate(request => {%get})->{valid}, 'still usable';
};

subtest 'commands' => sub {
  my($humbug, $transport) = fake_client();
  $humbug->validate(request => {%get}) for 1..2;
  $humbug->close;
  is $transport->sent, [
    { id => 1, type => 'initialize', params => { protocol_version => 1, spec => { path => match qr{/corpus/pets\.yaml$} } } },
    { id => 2, type => 'validate',   params => { request => {%get} } },
    { id => 3, type => 'validate',   params => { request => {%get} } },
    { id => 4, type => 'shutdown' },
  ], 'initialize, validates and shutdown with increasing ids';
};

subtest 'no shutdown when the transport outlives the session' => sub {
  my($humbug, $transport) = fake_client(ends_with_shutdown => 0);
  ok $humbug->close, 'close';
  is [ map { $_->{type} } $transport->sent->@* ], ['initialize'], 'shutdown not sent';
  ok !$transport->is_open, 'transport closed';
};

subtest 'result passed through unchanged' => sub {
  my $reply = {
    valid => false, complete => false, has_violations => false,
    future_field => { nested => [1, 2] },
    request => {
      status => 'incomplete',
      diagnostics => [
        { id => 'd1', code => 'future.code', severity => 'warning', suppressed_by => undef, brand_new => ['a'] },
      ],
    },
  };
  my($humbug) = fake_client(responder => sub ($command, $line) {
    $command->{type} eq 'validate' ? { id => $command->{id}, type => 'result', result => $reply } : undef;
  });
  is $humbug->validate(request => {%get}), $reply, 'unknown fields and codes kept';
};

subtest 'initialize' => sub {
  my($humbug) = fake_client(responder => sub ($command, $line) {
    return undef unless $command->{type} eq 'initialize';
    return { id => 1, type => 'result', result => {
      protocol_version => 1,
      specification    => { openapi_version => '3.1.0', title => 'Fake', future => 1 },
      limits           => { max_body_bytes => 16, max_future_thing => 7 },
      implementation   => { name => 'fake', version => '1' },
      something_new    => 1,
    } };
  });
  is $humbug->specification, { openapi_version => '3.1.0', title => 'Fake', future => 1 }, 'specification';
  is $humbug->limits, { max_body_bytes => 16, max_future_thing => 7 }, 'limits, unknown keys kept';
  is $humbug->implementation, { name => 'fake', version => '1' }, 'implementation';

  ($humbug) = fake_client();
  is $humbug->limits, U(), 'limits optional';
  is $humbug->implementation, U(), 'implementation optional';

  for my $case (
    [ 'no specification',     { protocol_version => 1 } ],
    [ 'wrong version',        { protocol_version => 2, specification => {} } ],
    [ 'specification string', { protocol_version => 1, specification => 'x' } ],
  ) {
    my($name, $result) = @$case;
    my $error = dies {
      fake_client(responder => sub ($command, $line) {
        $command->{type} eq 'initialize' ? { id => 1, type => 'result', result => $result } : undef;
      });
    };
    is [ $error->kind, $error->code ], [ 'protocol', 'client.unexpected_reply' ], $name;
  }

  my $error = dies {
    fake_client(responder => sub ($command, $line) {
      $command->{type} eq 'initialize' ? { id => 1, type => 'error', error => { code => 'spec.invalid', message => 'bad' } } : undef;
    });
  };
  is [ $error->kind, $error->code ], [ 'sidecar', 'spec.invalid' ], 'sidecar error from initialize';
};

subtest 'transport failure ends the client' => sub {
  my($humbug, $transport);
  ($humbug, $transport) = fake_client(responder => sub ($command, $line) {
    return undef unless $command->{type} eq 'validate';
    $transport->abort;
    OpenAPI::Humbug::Error->throw(kind => 'transport', code => 'client.eof', message => 'gone');
  });
  my $error = dies { $humbug->validate(request => {%get}) };
  is [ $error->kind, $error->code ], [ 'transport', 'client.eof' ], 'transport error passed through';
  is dies { $humbug->validate(request => {%get}) }->kind, 'closed', 'client unusable afterwards';
};

done_testing;
