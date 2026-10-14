use Test2::V0 -no_srand => 1;
use 5.042;
use lib 't/lib';
use MIME::Base64 qw( encode_base64 );
use OpenAPI::Humbug;
use FakeHumbug;

my $humbug = fake_humbug();

# the command the fake received
sub sent (%args) {
  my(undef, $command) = wire_command($humbug->validate(%args));
  return $command;
}

# the raw command line the fake received
sub sent_line (%args) {
  my($line) = wire_command($humbug->validate(%args));
  return $line;
}

subtest 'one JSON object per line' => sub {
  my $line = sent_line(request => {
    method  => 'GET',
    url     => "https://x/\n",
    headers => [["X-A\nB", "line\nbreak"]],
    body    => "a\nb\n",
  });
  like $line, qr/\A\{[^\n]*\}\n\z/, 'exactly one line, newline terminated';
};

subtest 'request shape' => sub {
  is sent(request => { method => 'get', url => 'https://api.example.test/a/../b?q=1&q=2' }), {
    id     => D(),
    type   => 'validate',
    params => {
      request => { method => 'get', url => 'https://api.example.test/a/../b?q=1&q=2' },
    },
  }, 'method and url sent as is, no headers or body keys';
};

subtest 'headers' => sub {
  my $command = sent(request => {
    method  => 'GET',
    url     => 'https://x/',
    headers => [
      ['Set-Cookie',   'a=1'],
      ['content-TYPE', 'application/json'],
      ['Set-Cookie',   'b=2, c=3'],
      ['X-Empty',      ''],
      ['X-Space',      '  padded  '],
      ['X-Bin',        "\xFF\xFE"],
      ['X-Zero',       '0'],
    ],
  });
  is $command->{params}{request}{headers}, [
    ['Set-Cookie',   encode_base64('a=1', ''),              T()],
    ['content-TYPE', encode_base64('application/json', ''), T()],
    ['Set-Cookie',   encode_base64('b=2, c=3', ''),         T()],
    ['X-Empty',      '',                                    T()],
    ['X-Space',      encode_base64('  padded  ', ''),       T()],
    ['X-Bin',        '//4=',                                T()],
    ['X-Zero',       'MA==',                                T()],
  ], 'order, duplicates, casing, empty and binary values; every value base64; names never encoded';

  is sent(request => { method => 'GET', url => 'https://x/', headers => [] })->{params}{request}{headers}, [], 'empty headers';
};

subtest 'header values are bytes' => sub {
  my $upgraded = "caf\xE9";
  utf8::upgrade($upgraded);
  my $encoded = "\xE2\x98\xBA";

  my $headers = sent(request => {
    method  => 'GET',
    url     => 'https://x/',
    headers => [['X-Upgraded', $upgraded], ['X-Encoded', $encoded]],
  })->{params}{request}{headers};

  is $headers->[0][1], encode_base64("caf\xE9", ''), 'utf8-flagged string sends its characters as bytes, not double-encoded';
  is $headers->[1][1], '4pi6', 'UTF-8 bytes sent unchanged';
};

subtest 'bodies' => sub {
  ok !exists sent(request => { method => 'GET', url => 'https://x/' })->{params}{request}{body_base64}, 'absent body';
  ok !exists sent(request => { method => 'GET', url => 'https://x/', body => undef })->{params}{request}{body_base64}, 'undef body is absent';
  is sent(request => { method => 'POST', url => 'https://x/', body => '' })->{params}{request}{body_base64}, '', 'empty body is present';
  is sent(request => { method => 'POST', url => 'https://x/', body => '0' })->{params}{request}{body_base64}, 'MA==', 'false-looking body';

  my $binary = join '', map { chr } 0..255;
  my $wire = sent(request => { method => 'POST', url => 'https://x/', body => $binary x 1000 })->{params}{request}{body_base64};
  is $wire, encode_base64($binary x 1000, ''), 'binary body, padded base64 without line breaks';
  unlike $wire, qr/\n/, 'no line breaks';

  my $upgraded = "\xE9";
  utf8::upgrade($upgraded);
  is sent(request => { method => 'POST', url => 'https://x/', body => $upgraded })->{params}{request}{body_base64}, '6Q==', 'utf8-flagged body';

  is sent(request => { method => 'POST', url => 'https://x/', body => "\xE2\x98\xBA" })->{params}{request}{body_base64}, '4pi6', 'UTF-8 bytes';

  my $big = 'x' x (3 * 1024 * 1024);
  is length(sent(request => { method => 'POST', url => 'https://x/', body => $big })->{params}{request}{body_base64}),
    4 * 1024 * 1024, 'large body written completely';
};

subtest 'response' => sub {
  is sent(
    request  => { method => 'GET', url => 'https://x/' },
    response => { status => '201', headers => [['Content-Type', 'application/json']], body => '{}' },
  )->{params}{response}, {
    status      => 201,
    headers     => [['Content-Type', encode_base64('application/json', ''), T()]],
    body_base64 => 'e30=',
  }, 'response with numeric status';

  is sent(
    request  => { method => 'GET', url => 'https://x/' },
    response => { status => 204 },
  )->{params}{response}, { status => 204 }, 'response without body';

  my $line = sent_line(request => { method => 'GET', url => 'https://x/' }, response => { status => '200' });
  like $line, qr/"status":200[,}]/, 'status is a JSON number';
};

subtest 'validate selector' => sub {
  my $command = sent(request => { method => 'GET', url => 'https://x/' });
  ok !exists $command->{params}{validate}, 'omitted by default';

  my($line, $sent) = wire_command($humbug->validate(
    request  => { method => 'GET', url => 'https://x/' },
    response => { status => 200 },
    validate => { request => 0, response => 'yes' },
  ));
  is $sent->{params}{validate}, { request => F(), response => T() }, 'selector as JSON booleans';
  like $line, qr/"validate":\{"request":false,"response":true\}/, 'real JSON booleans on the wire';

  is sent(request => { method => 'GET', url => 'https://x/' }, validate => {})->{params}{validate}, {}, 'empty selector';
};

$humbug->close;

done_testing;
