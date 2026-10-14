use Test2::V0 -no_srand => 1;
use 5.042;
use lib 't/lib';
use Path::Tiny qw( path );
use POSIX ();
use Time::HiRes ();
use OpenAPI::Humbug;
use OpenAPI::Humbug::Transport::Command;
use FakeHumbug;

my $fake = path('t/bin/fake-humbug')->absolute->stringify;

# construction must not wait for the child to exit (the exec-status pipe has to close on exec),
# so a spawn that blocks fails the test instead of hanging it
sub transport (%args) {
  local $SIG{ALRM} = sub { die "spawning blocked\n" };
  alarm 5;
  my $t = eval { OpenAPI::Humbug::Transport::Command->new(executable => $^X, args => [$fake], %args) };
  my $error = $@;
  alarm 0;
  die $error unless $t;
  return $t;
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

subtest 'exec failure' => sub {
  # passes the -f and -x checks, but exec fails: the interpreter does not exist
  my $dir = Path::Tiny->tempdir;
  my $script = $dir->child('humbug');
  $script->spew("#!/nonexistent/interpreter\n");
  $script->chmod(0755);

  my $error = dies { OpenAPI::Humbug::Transport::Command->new(executable => "$script") };
  isa_ok $error, 'OpenAPI::Humbug::Error';
  is [ $error->kind, $error->code ], [ 'transport', 'client.spawn_failed' ], 'kind and code';
  like $error->message, qr/^cannot execute '\Q$script\E': /, 'says exec failed';
  is waitpid(-1, POSIX::WNOHANG()), -1, 'no child left behind';

  $error = dies { OpenAPI::Humbug->new(spec => 'corpus/pets.yaml', executable => "$script") };
  is [ $error->kind, $error->code ], [ 'transport', 'client.spawn_failed' ], 'through the client';
  is waitpid(-1, POSIX::WNOHANG()), -1, 'no child left behind';
};

subtest 'construction does not wait for the child to exit' => sub {
  # the exec-status pipe must close on exec, or new would block until the child exits
  my $t = eval { transport(args => [$fake, 'hang']) };
  ok $t, 'returned while the child runs' or diag $@;
  ok !reaped($t->pid), 'child still running' if $t;
  $t->abort if $t;
};

subtest 'caller with closed standard handles' => sub {
  # pipe ends can then land on fd 0, 1 or 2
  for my $closed ([qw( STDIN )], [qw( STDIN STDOUT )], [qw( STDIN STDOUT STDERR )]) {
    my $child = fork // die "fork: $!";
    if($child == 0) {
      for my $name (@$closed) {
        no strict 'refs';
        close *{"main::$name"};
      }
      my $ok = eval {
        my $t = transport();
        my $reply = $t->exchange($initialize, 5);
        $reply =~ /"id":1/ && $t->close(5);
      };
      POSIX::_exit($ok ? 0 : 1);
    }
    waitpid $child, 0;
    is $? >> 8, 0, "works with @$closed closed";
  }
};

subtest 'close after the child died' => sub {
  my $t = transport();
  my $pid = $t->pid;
  kill 'KILL', $pid;
  my $start = Time::HiRes::time();
  ok !$t->close(5), 'killed child is not a clean end';
  ok Time::HiRes::time() - $start < 2, 'did not wait for the grace period';
  ok reaped($pid), 'reaped';

  $t = transport();
  $pid = $t->pid;
  kill 'KILL', $pid;
  waitpid $pid, 0;
  ok lives { $t->close(5) }, 'child already reaped by someone else';

  $t = transport();
  $pid = $t->pid;
  kill 'KILL', $pid;
  ok lives { undef $t }, 'destroy after the child died';
  ok reaped($pid), 'reaped';
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
