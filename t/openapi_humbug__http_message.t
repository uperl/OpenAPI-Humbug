use Test2::V0 -no_srand => 1;
use 5.042;
use Test2::Require::Module 'HTTP::Message' => '6.00';
use lib 't/lib';
use Data::Dumper ();
use Encode ();
use MIME::Base64 qw( encode_base64 );
use HTTP::Request;
use HTTP::Response;
use URI;
use OpenAPI::Humbug;
use FakeTransport;

# HTTP::Request and HTTP::Response are converted to the wire form; checked against what the fake
# transport received

my($humbug, $transport) = fake_client();

sub sent (@args) {
  $humbug->validate(@args);
  return $transport->sent->[-1]{params};
}

sub b64 ($bytes) { encode_base64($bytes, '') }

sub header_lines (@pairs) { [ map { [ $_->[0], b64($_->[1]), T() ] } @pairs ] }

sub snapshot ($object) {
  local $Data::Dumper::Sortkeys = 1;
  local $Data::Dumper::Deparse  = 0;
  return Data::Dumper::Dumper($object);
}

sub argument_error ($code, $like, $name) {
  my $error = dies { $code->() };
  is [ $error->kind, $error->code ], [ 'argument', 'client.argument' ], $name or diag $error;
  like $error->message, $like, "$name: message";
}

sub get ($url = 'https://api.example.test/pets/1') { HTTP::Request->new(GET => $url) }

subtest 'request only' => sub {
  my $req = HTTP::Request->new(POST => 'https://api.example.test/pets?limit=5#frag',
    [ 'Content-Type' => 'application/json', 'X-Request-Id' => 'abc123' ], qq|{"name":1}\n|);
  is sent(request => $req), {
    request => {
      method      => 'POST',
      url         => 'https://api.example.test/pets?limit=5',
      headers     => header_lines(['Content-Type', 'application/json'], ['X-Request-Id', 'abc123']),
      body_base64 => b64(qq|{"name":1}\n|),
    },
  }, 'method, absolute url without fragment, headers and raw body';
};

subtest 'request and response' => sub {
  my $res = HTTP::Response->parse(join "\x0d\x0a",
    'HTTP/1.1 200 OK',
    'Set-Cookie: a=1; Path=/',
    'Content-Type: application/json',
    'set-cookie: b=2, c=3',
    'X-Trace: one',
    'X-Trace: two',
    '',
    '{"id":1}',
  );
  is sent(request => get(), response => $res), {
    request => {
      method  => 'GET',
      url     => 'https://api.example.test/pets/1',
      headers => [],
    },
    response => {
      status      => 200,
      headers     => header_lines(
        ['Content-Type', 'application/json'],
        ['Set-Cookie', 'a=1; Path=/'],
        ['Set-Cookie', 'b=2, c=3'],
        ['X-Trace', 'one'],
        ['X-Trace', 'two'],
      ),
      body_base64 => b64('{"id":1}'),
    },
  }, 'repeated headers kept as separate lines in order';
};

subtest 'response with its associated request' => sub {
  my $res = HTTP::Response->new(200, 'OK', [ 'Content-Type' => 'application/json' ], '{"id":1}');
  $res->request(get('https://api.example.test/pets/1?from=response'));

  my $params = sent(response => $res);
  is $params->{request}{url}, 'https://api.example.test/pets/1?from=response', 'request taken from the response';
  is $params->{response}{status}, 200, 'response';

  $params = sent(response => $res, validate => { request => 0, response => 1 });
  is $params->{request}{url}, 'https://api.example.test/pets/1?from=response', 'still sent when only the response is checked';
  is $params->{validate}, { request => F(), response => T() }, 'selector passed through';

  $params = sent(request => get('https://api.example.test/explicit'), response => $res);
  is $params->{request}{url}, 'https://api.example.test/explicit', 'explicit request wins';

  $params = sent(request => { method => 'GET', url => 'https://hash.test/' }, response => $res);
  is $params->{request}{url}, 'https://hash.test/', 'explicit hashref request wins';

  my $orphan = HTTP::Response->new(200);
  argument_error sub { $humbug->validate(response => $orphan) }, qr/no associated request/, 'response without a request';

  argument_error sub { $humbug->validate(response => { status => 200 }) }, qr/request is required/, 'hashref response alone';

  argument_error sub { $humbug->validate($res) }, qr/response => /, 'positional response rejected';
  argument_error sub { $humbug->validate($res, validate => {}) }, qr/response => /, 'positional response with options rejected';
};

subtest 'bodies' => sub {
  my $binary = join '', map { chr } 0..255;
  my $req = HTTP::Request->new(PUT => 'https://x.test/blob', [ 'Content-Length' => 256 ], $binary);
  is sent(request => $req)->{request}{body_base64}, b64($binary), 'binary body';

  $req = HTTP::Request->new(POST => 'https://x.test/e', [ 'Content-Length' => 0 ], '');
  is sent(request => $req)->{request}{body_base64}, '', 'Content-Length: 0 is an empty body';

  $req = HTTP::Request->new(POST => 'https://x.test/e', [ 'Transfer-Encoding' => 'chunked' ]);
  is sent(request => $req)->{request}{body_base64}, '', 'Transfer-Encoding with no data is an empty body';

  ok !exists sent(request => get())->{request}{body_base64}, 'no Content-Length or Transfer-Encoding: no body';

  my $gzip = HTTP::Response->new(200, 'OK', [ 'Content-Encoding' => 'gzip' ], "\x1f\x8b\x08\x00");
  $gzip->request(get());
  is sent(response => $gzip)->{response}{body_base64}, b64("\x1f\x8b\x08\x00"), 'raw content, not decoded_content';

  for my $status (204, 304, 101) {
    my $res = HTTP::Response->new($status);
    ok !exists sent(request => get(), response => $res)->{response}{body_base64}, "$status has no body";
  }

  my $res = HTTP::Response->new(200);
  is sent(request => get(), response => $res)->{response}{body_base64}, '', '200 with no content is an empty body';

  $res = HTTP::Response->new(200, 'OK', [ 'Content-Length' => 3 ]);
  $res->request(HTTP::Request->new(HEAD => 'https://x.test/'));
  ok !exists sent(response => $res)->{response}{body_base64}, 'response to HEAD has no body';

  my $text = HTTP::Request->new(POST => 'https://x.test/');
  $text->content(Encode::encode('UTF-8', "\x{263A}"));
  is sent(request => $text)->{request}{body_base64}, '4pi6', 'UTF-8 bytes unchanged';
};

subtest 'header values' => sub {
  my $req = get();
  $req->header('X-Latin' => "caf\xE9");
  $req->header('X-Utf8'  => "\xE2\x98\xBA");
  $req->header('X-Uri'   => URI->new('https://x.test/a'));
  $req->header('X-Empty' => '');
  is sent(request => $req)->{request}{headers}, header_lines(
    ['X-Empty', ''],
    ['X-Latin', "caf\xE9"],
    ['X-Uri', 'https://x.test/a'],
    ['X-Utf8', "\xE2\x98\xBA"],
  ), 'raw bytes, empty values and objects that stringify';

  my $folded = HTTP::Response->parse("HTTP/1.1 200 OK\x0d\x0aX-Fold: one\x0d\x0a two\x0d\x0a\x0d\x0a");
  is sent(request => get(), response => $folded)->{response}{headers}, header_lines(['X-Fold', 'one two']), 'folded value unfolded';

  my $wide = get();
  $wide->header('X-Wide' => "\x{263A}");
  argument_error sub { $humbug->validate(request => $wide) }, qr/above 0xFF/, 'characters above 0xFF';

  my $ref = get();
  $ref->header('X-Ref' => { a => 1 });
  argument_error sub { $humbug->validate(request => $ref) }, qr/not a string/, 'unblessed reference value';
};

subtest 'urls' => sub {
  argument_error sub { $humbug->validate(request => get('/pets/1')) }, qr/not absolute/, 'relative URI';

  my $with_host = get('/pets/1');
  $with_host->header(Host => 'api.example.test');
  argument_error sub { $humbug->validate(request => $with_host) }, qr/not absolute/, 'Host header is not enough';

  argument_error sub { $humbug->validate(request => get('http:/no-host')) }, qr/not absolute/, 'scheme without host';
  argument_error sub { $humbug->validate(request => get('mailto:a@b.test')) }, qr/not absolute/, 'URI without a host';
  argument_error sub { $humbug->validate(request => HTTP::Request->new('GET')) }, qr/no URI/, 'no URI';

  my $req = get('https://user:secret@api.example.test:8443/p?q=1');
  is sent(request => $req)->{request}{url}, 'https://api.example.test:8443/p?q=1', 'credentials are not part of the effective URL';
  is $req->uri->as_string, 'https://user:secret@api.example.test:8443/p?q=1', 'request URI unchanged';
};

subtest 'messages that cannot be converted' => sub {
  my $parts = HTTP::Request->new(POST => 'https://x.test/', [ 'Content-Type' => 'multipart/form-data' ]);
  $parts->add_part(HTTP::Message->new([ 'Content-Disposition' => 'form-data; name="a"' ], 'x'));
  my $before = snapshot($parts);
  argument_error sub { $humbug->validate(request => $parts) }, qr/parts/, 'body built from parts';
  is snapshot($parts), $before, 'not generated as a side effect';

  my $code = HTTP::Request->new(POST => 'https://x.test/', [], sub { undef });
  argument_error sub { $humbug->validate(request => $code) }, qr/code reference/, 'content from a code reference';

  argument_error sub { $humbug->validate(request => HTTP::Response->new(200)) }, qr/HTTP::Request/, 'response as request';
  argument_error sub { $humbug->validate(request => get(), response => get()) }, qr/HTTP::Response/, 'request as response';
  argument_error sub { $humbug->validate(request => bless({}, 'Some::Thing')) }, qr/HTTP::Request/, 'other object';
};

subtest 'objects are not changed' => sub {
  my $req = HTTP::Request->new(POST => 'https://u:p@api.example.test/pets#f',
    [ 'Content-Type' => 'application/json', 'X-Fold' => "a\x0d\x0a b" ], '{}');
  my $res = HTTP::Response->parse("HTTP/1.1 201 Created\x0d\x0aSet-Cookie: a=1\x0d\x0aSet-Cookie: b=2\x0d\x0a\x0d\x0a{}");
  $res->request($req);
  my @before = map { snapshot($_) } $req, $res;

  sent(response => $res);
  sent(request => $req, response => $res);

  is [ map { snapshot($_) } $req, $res ], \@before, 'request and response unchanged';
};

$humbug->close;

done_testing;
