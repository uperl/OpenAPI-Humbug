use Test2::V0 -no_srand => 1;
use 5.042;
use Test2::Require::Module 'Mojolicious' => '9.0';
use lib 't/lib';
use Data::Dumper ();
use MIME::Base64 qw( encode_base64 );
use Mojo::Message::Request;
use Mojo::Message::Response;
use Mojo::Transaction::HTTP;
use Mojo::URL;
use Mojo::UserAgent;
use Mojolicious::Lite -signatures;
use OpenAPI::Humbug;
use FakeTransport;

# Mojo objects are converted to the wire form; checked against what the fake transport received

my($humbug, $transport) = fake_client();

sub sent (@args) {
  $humbug->validate(@args);
  return $transport->sent->[-1]{params};
}

sub b64 ($bytes) { encode_base64($bytes, '') }

sub header_lines (@pairs) { [ map { [ $_->[0], b64($_->[1]), T() ] } @pairs ] }

sub parse_request ($raw) { Mojo::Message::Request->new->parse($raw) }

sub parse_response ($raw) { Mojo::Message::Response->new->parse($raw) }

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

subtest 'request only' => sub {
  my $req = parse_request(join "\x0d\x0a",
    'POST /pets?limit=5&q=a%20b HTTP/1.1',
    'Host: api.example.test',
    'Content-Type: application/json',
    'Content-Length: 11',
    '',
    '{"name":1}' . "\n",
  );
  is sent(request => $req), {
    request => {
      method      => 'POST',
      url         => 'http://api.example.test/pets?limit=5&q=a%20b',
      headers     => header_lines(['Content-Length', '11'], ['Content-Type', 'application/json'], ['Host', 'api.example.test']),
      body_base64 => b64(qq|{"name":1}\n|),
    },
  }, 'method, absolute url, headers and body bytes';
};

subtest 'request and response' => sub {
  my $req = Mojo::Message::Request->new->method('GET')->url(Mojo::URL->new('https://api.example.test/pets/1#section'));
  my $res = parse_response(join "\x0d\x0a",
    'HTTP/1.1 200 OK',
    'Content-Type: application/json',
    'Set-Cookie: a=1; Path=/',
    'Set-Cookie: b=2, c=3',
    'X-Trace: one',
    'x-trace: two',
    'Content-Length: 8',
    '',
    '{"id":1}',
  );
  ok $res->is_finished, 'response parsed';
  is sent(request => $req, response => $res), {
    request => {
      method  => 'GET',
      url     => 'https://api.example.test/pets/1',
      headers => [],
    },
    response => {
      status      => 200,
      headers     => header_lines(
        ['Content-Length', '8'],
        ['Content-Type', 'application/json'],
        ['Set-Cookie', 'a=1; Path=/'],
        ['Set-Cookie', 'b=2, c=3'],
        ['X-Trace', 'one'],
        ['X-Trace', 'two'],
      ),
      body_base64 => b64('{"id":1}'),
    },
  }, 'fragment dropped; repeated headers kept as separate lines in order';

  is sent(request => { method => 'GET', url => 'https://x/' }, response => $res)->{response}{status}, 200,
    'hashref request with Mojo response';
  is sent(request => $req, response => { status => 204 })->{response}, { status => 204 },
    'Mojo request with hashref response';
};

subtest 'validate selector' => sub {
  my $req = Mojo::Message::Request->new->url(Mojo::URL->new('https://x/'));
  my $res = parse_response("HTTP/1.1 204 No Content\x0d\x0a\x0d\x0a");
  is sent(request => $req, response => $res, validate => { request => 0 })->{validate}, { request => F() }, 'passed through';
};

subtest 'bodies' => sub {
  my $binary = join '', map { chr } 0..255;
  my $req = parse_request("PUT /blob HTTP/1.1\x0d\x0aHost: x\x0d\x0aContent-Length: 256\x0d\x0a\x0d\x0a$binary");
  is sent(request => $req)->{request}{body_base64}, b64($binary), 'binary body';

  $req = parse_request("POST /e HTTP/1.1\x0d\x0aHost: x\x0d\x0aContent-Length: 0\x0d\x0a\x0d\x0a");
  is sent(request => $req)->{request}{body_base64}, '', 'Content-Length: 0 is an empty body';

  $req = parse_request("POST /e HTTP/1.1\x0d\x0aHost: x\x0d\x0aTransfer-Encoding: chunked\x0d\x0a\x0d\x0a0\x0d\x0a\x0d\x0a");
  is sent(request => $req)->{request}{body_base64}, '', 'chunked with no data is an empty body';

  $req = parse_request("GET /e HTTP/1.1\x0d\x0aHost: x\x0d\x0a\x0d\x0a");
  ok !exists sent(request => $req)->{request}{body_base64}, 'no Content-Length or Transfer-Encoding: no body';

  my $chunked = parse_request("POST /c HTTP/1.1\x0d\x0aHost: x\x0d\x0aTransfer-Encoding: chunked\x0d\x0a\x0d\x0a3\x0d\x0aabc\x0d\x0a2\x0d\x0ade\x0d\x0a0\x0d\x0a\x0d\x0a");
  is sent(request => $chunked)->{request}{body_base64}, b64('abcde'), 'chunked body is de-chunked';

  my $get = Mojo::Message::Request->new->url(Mojo::URL->new('https://x/'));
  my $res = parse_response("HTTP/1.1 204 No Content\x0d\x0a\x0d\x0a");
  ok !exists sent(request => $get, response => $res)->{response}{body_base64}, '204 has no body';

  $res = parse_response("HTTP/1.1 304 Not Modified\x0d\x0a\x0d\x0a");
  ok !exists sent(request => $get, response => $res)->{response}{body_base64}, '304 has no body';

  $res = parse_response("HTTP/1.1 200 OK\x0d\x0aContent-Length: 0\x0d\x0a\x0d\x0a");
  is sent(request => $get, response => $res)->{response}{body_base64}, '', '200 with Content-Length: 0 is an empty body';

  my $head = Mojo::Message::Request->new->method('HEAD')->url(Mojo::URL->new('https://x/'));
  $res = parse_response("HTTP/1.1 200 OK\x0d\x0aContent-Length: 0\x0d\x0a\x0d\x0a");
  ok !exists sent(request => $head, response => $res)->{response}{body_base64}, 'response to HEAD has no body';

  $res = Mojo::Message::Response->new->code(200);
  is sent(request => $get, response => $res)->{response}{body_base64}, '', 'generated 200 with no body is an empty body';

  my $text = Mojo::Message::Request->new->method('POST')->url(Mojo::URL->new('https://x/'));
  $text->body(Mojo::Util::encode('UTF-8', "\x{263A}"));
  is sent(request => $text)->{request}{body_base64}, '4pi6', 'UTF-8 bytes unchanged';
};

subtest 'non-ASCII header values' => sub {
  my $req = parse_request("GET /h HTTP/1.1\x0d\x0aHost: x\x0d\x0aX-Latin: caf\xE9\x0d\x0aX-Utf8: \xE2\x98\xBA\x0d\x0a\x0d\x0a");
  is sent(request => $req)->{request}{headers}, header_lines(['Host', 'x'], ['X-Latin', "caf\xE9"], ['X-Utf8', "\xE2\x98\xBA"]),
    'raw bytes sent as is';

  my $wide = Mojo::Message::Request->new->url(Mojo::URL->new('https://x/'));
  $wide->headers->add('X-Wide' => "\x{263A}");
  argument_error sub { $humbug->validate(request => $wide) }, qr/above 0xFF/, 'characters above 0xFF';
};

subtest 'urls' => sub {
  my $req = Mojo::Message::Request->new->url(Mojo::URL->new('/pets?a=1'));
  argument_error sub { $humbug->validate(request => $req) }, qr/relative/, 'relative with no base';

  $req->url->base(Mojo::URL->new('https://api.example.test:8443'));
  is sent(request => $req)->{request}{url}, 'https://api.example.test:8443/pets?a=1', 'relative resolved against the base';

  $req = Mojo::Message::Request->new->url(Mojo::URL->new('/pets'));
  $req->url->base(Mojo::URL->new('/prefix'));
  argument_error sub { $humbug->validate(request => $req) }, qr/relative/, 'base without scheme and host';

  $req = Mojo::Message::Request->new->url(Mojo::URL->new('https://user:secret@api.example.test/p'));
  is sent(request => $req)->{request}{url}, 'https://api.example.test/p', 'credentials are not part of the effective URL';
  is $req->url->to_unsafe_string, 'https://user:secret@api.example.test/p', 'request URL unchanged';
};

subtest 'messages that cannot be converted' => sub {
  my $get = Mojo::Message::Request->new->url(Mojo::URL->new('https://x/'));

  argument_error sub { $humbug->validate(request => $get, response => Mojo::Message::Response->new) },
    qr/no status code/, 'response without a status';

  my $partial = parse_response("HTTP/1.1 200 OK\x0d\x0aContent-Length: 10\x0d\x0a\x0d\x0aabc");
  argument_error sub { $humbug->validate(request => $get, response => $partial) },
    qr/still being received/, 'response still being received';

  my $multipart = Mojo::Message::Request->new->method('POST')->url(Mojo::URL->new('https://x/'));
  $multipart->content(Mojo::Content::MultiPart->new(parts => [Mojo::Content::Single->new]));
  argument_error sub { $humbug->validate(request => $multipart) }, qr/multipart/, 'multipart body';

  my $dynamic = Mojo::Message::Request->new->method('POST')->url(Mojo::URL->new('https://x/'));
  $dynamic->content->write('abc');
  argument_error sub { $humbug->validate(request => $dynamic) }, qr/streamed/, 'streamed body';

  argument_error sub { $humbug->validate(request => Mojo::Message::Response->new) }, qr/Mojo::Message::Request/, 'response as request';
  argument_error sub { $humbug->validate(request => {%$get}) }, qr/./, 'unblessed copy is just a bad hash';
  argument_error sub { $humbug->validate(request => $get, response => $get) }, qr/Mojo::Message::Response/, 'request as response';
  argument_error sub { $humbug->validate(bless {}, 'Some::Thing') }, qr/Mojo::Transaction::HTTP/, 'other object as transaction';
  argument_error sub { $humbug->validate(Mojo::Transaction::HTTP->new, request => {}) }, qr/cannot be given with a transaction/, 'transaction and request';
};

# an app and a user agent talking to it in process
app->log->level('fatal');
get '/pets/:id' => sub ($c) {
  $c->res->headers->add('Set-Cookie' => 'a=1');
  $c->res->headers->add('Set-Cookie' => 'b=2');
  $c->render(json => { id => 0 + $c->param('id') });
};
my $ua = Mojo::UserAgent->new;
$ua->server->app(app);

subtest 'transaction' => sub {
  my $tx = $ua->get('/pets/7?x=1');
  ok $tx->res->is_finished, 'finished';
  my $params = sent($tx);
  is $params->{request}{method}, 'GET', 'request method';
  like $params->{request}{url}, qr{^http://127\.0\.0\.1:\d+/pets/7\?x=1$}, 'absolute url';
  is $params->{response}{status}, 200, 'response included';
  is $params->{response}{body_base64}, b64('{"id":7}'), 'response body bytes';
  is [ grep { $_->[0] eq 'Set-Cookie' } $params->{response}{headers}->@* ], header_lines(['Set-Cookie', 'a=1'], ['Set-Cookie', 'b=2']),
    'Set-Cookie lines kept separate';

  is sent($tx, validate => { response => 1, request => 0 })->{validate}, { request => F(), response => T() }, 'with selector';
};

subtest 'unfinished transaction' => sub {
  my $tx = $ua->build_tx(GET => 'https://api.example.test/pets/1');
  my $params = sent($tx);
  ok exists $params->{request}, 'request validated';
  ok !exists $params->{response}, 'unsent response left out';

  argument_error sub { $humbug->validate($tx, validate => { response => 1 }) }, qr/not complete/, 'asking for it is an error';

  # a response that is still arriving is left out too
  $tx = Mojo::Transaction::HTTP->new;
  $tx->req->url(Mojo::URL->new('https://api.example.test/pets/1'));
  $tx->res->parse("HTTP/1.1 200 OK\x0d\x0aContent-Length: 10\x0d\x0a\x0d\x0aabc");
  ok !exists sent($tx)->{response}, 'partially received response left out';
};

subtest 'objects are not changed' => sub {
  my $tx = $ua->get('/pets/3');
  my($req, $res) = ($tx->req, $tx->res);
  my $finished = 0;
  $res->on(finish => sub { $finished++ });
  my @before = map { snapshot($_) } $tx, $req, $res;

  sent($tx);
  sent(request => $req, response => $res);

  is [ map { snapshot($_) } $tx, $req, $res ], \@before, 'transaction, request and response unchanged';
  is $finished, 0, 'no events emitted';

  my $parsed = parse_request("POST /p HTTP/1.1\x0d\x0aHost: x\x0d\x0aContent-Length: 2\x0d\x0a\x0d\x0a{}");
  my $before = snapshot($parsed);
  sent(request => $parsed);
  is snapshot($parsed), $before, 'parsed request unchanged';

  my $built = Mojo::Message::Response->new->code(200);
  $built->headers->content_type('text/plain');
  $built->body('x');
  $before = snapshot($built);
  sent(request => { method => 'GET', url => 'https://x/' }, response => $built);
  is snapshot($built), $before, 'generated response unchanged (no Content-Length added)';
  ok !defined $built->headers->content_length, 'no Content-Length';
};

$humbug->close;

done_testing;
