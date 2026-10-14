use Test2::V0 -no_srand => 1;
use 5.042;
use lib 't/lib';
use Path::Tiny qw( path );
use OpenAPI::Humbug::Transport::Command;
use FakeHumbug;

my $fake = path('t/bin/fake-humbug')->absolute->stringify;

sub transport (%args) {
  return OpenAPI::Humbug::Transport::Command->new(executable => $^X, args => [$fake], %args);
}

my $initialize = qq|{"id":1,"type":"initialize","params":{"protocol_version":1,"spec":{"path":"x"}}}\n|;

subtest 'exchange and close' => sub {
  my $t = transport();
  isa_ok $t, 'OpenAPI::Humbug::Transport';
  is $t->executable, $^X, 'executable';
  ok $t->ends_with_shutdown, 'the sidecar ends with the connection';
  ok $t->is_open, 'open';
  my $pid = $t->pid;
  ok $pid, 'pid';

  my $reply = $t->exchange($initialize, 5);
  like $reply, qr/\A\{.*"id":1.*\}\n\z/, 'one reply line, with its newline';
  is $t->stderr, '', 'nothing on stderr';

  ok $t->close(5), 'closing stdin ends the child cleanly';
  ok !$t->is_open, 'closed';
  ok reaped($pid), 'reaped';
  ok $t->close(5), 'close again returns the same answer';

  my $error = dies { $t->exchange($initialize, 5) };
  is [ $error->kind, $error->code ], [ 'closed', 'client.closed' ], 'exchange after close';
};

subtest 'abort' => sub {
  my $t = transport(args => [$fake, 'hang']);
  my $pid = $t->pid;
  $t->abort;
  ok reaped($pid), 'child terminated and reaped';
};

subtest 'timeout leaves it closed' => sub {
  my $t = transport(args => [$fake, 'hang']);
  my $pid = $t->pid;
  my $error = dies { $t->exchange($initialize, 0.3) };
  is [ $error->kind, $error->code ], [ 'timeout', 'client.timeout' ], 'timeout';
  ok !$t->is_open, 'closed';
  ok reaped($pid), 'reaped';
};

subtest 'spawn failures' => sub {
  my $error = dies { OpenAPI::Humbug::Transport::Command->new(executable => '/nonexistent/humbug') };
  is [ $error->kind, $error->code ], [ 'transport', 'client.spawn_failed' ], 'missing file';

  $error = dies { OpenAPI::Humbug::Transport::Command->new(executable => 'corpus/pets.yaml') };
  is [ $error->kind, $error->code ], [ 'transport', 'client.spawn_failed' ], 'not executable';

  $error = dies { OpenAPI::Humbug::Transport::Command->new(executable => '') };
  is [ $error->kind, $error->code ], [ 'argument', 'client.argument' ], 'empty name';
};

subtest 'destroy reaps' => sub {
  my $pid;
  {
    my $t = transport();
    $pid = $t->pid;
  }
  ok reaped($pid), 'reaped on destroy';
};

done_testing;
