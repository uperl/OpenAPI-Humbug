use Test2::V0 -no_srand => 1;
use 5.042;
use lib 't/lib';
use Time::HiRes ();
use OpenAPI::Humbug;
use FakeHumbug;

# Transport failures, through a client talking to the fake sidecar process (protocol failures
# are tested in memory in openapi_humbug__protocol.t)

# each case: a fresh client, one command that fails fatally, then checks that the child
# was reaped and the client refuses further use
sub fatal ($behavior, $kind, $code, %options) {
  my $humbug = fake_humbug($options{mode} // 'ok', $options{new} ? $options{new}->%* : ());
  my $pid = child_pid($humbug);

  $humbug->validate(request => { method => 'GET', url => "fake:$_" }) for ($options{before} // [])->@*;

  my $error = dies {
    $humbug->validate(
      request => { method => 'POST', url => "fake:$behavior", $options{body} ? (body => $options{body}) : () },
    );
  };
  isa_ok $error, 'OpenAPI::Humbug::Error';
  is [ $error->kind, $error->code ], [ $kind, $code ], 'kind and code' or diag $error;
  ok defined $error->stderr, 'stderr captured for the error';
  ok reaped($pid), 'child reaped';

  my $again = dies { $humbug->validate(request => { method => 'GET', url => 'https://x/' }) };
  is $again->kind, 'closed', 'client unusable afterwards';
  ok lives { $humbug->close }, 'close after failure does not throw';

  return $error;
}

subtest 'two replies' => sub {
  my $humbug = fake_humbug();
  my $pid = child_pid($humbug);
  # the second line may arrive with the first reply or just after it; either way it is caught
  # no later than the next command, and never taken as that command's reply
  my $error = dies {
    $humbug->validate(request => { method => 'GET', url => 'fake:extra' });
    Time::HiRes::sleep(0.2);
    $humbug->validate(request => { method => 'GET', url => 'https://x/' });
  };
  is [ $error->kind, $error->code ], [ 'protocol', 'client.unsolicited_output' ], 'kind and code' or diag $error;
  ok reaped($pid), 'child reaped';
};
subtest 'unexpected EOF' => sub { fatal eof     => transport => 'client.eof' };
subtest 'EOF mid line'   => sub { fatal partial => transport => 'client.eof' };

subtest 'child killed' => sub {
  my $error = fatal signal => transport => 'client.eof';
  like $error->message, qr/signal 9/, 'says how it died';
};

subtest 'reply too long' => sub {
  fatal huge => protocol => 'client.reply_too_long', new => { max_reply_bytes => 1000 };
};

subtest 'broken pipe' => sub {
  fatal anything => transport => 'client.broken_pipe', before => ['closestdin'], body => 'x' x (1024 * 1024);
};

subtest 'timeout' => sub {
  my $start = Time::HiRes::time();
  fatal hang => timeout => 'client.timeout', new => { timeout => 0.5 };
  my $elapsed = Time::HiRes::time() - $start;
  ok $elapsed < 5, "gave up promptly (${elapsed}s)";
};

subtest 'noisy stderr does not deadlock or corrupt stdout' => sub {
  my $humbug = fake_humbug('ok', max_stderr_bytes => 4096, timeout => 10);
  for (1..3) {
    my $result = $humbug->validate(request => { method => 'GET', url => 'fake:stderr' });
    ok $result->{valid}, "result $_ intact";
  }
  is length($humbug->stderr), 4096, 'stderr bounded';
  ok $humbug->close, 'close';
};

subtest 'close escalates when the child ignores shutdown and SIGTERM' => sub {
  my $humbug = fake_humbug('ok', timeout => 0.3);
  my $pid = child_pid($humbug);
  $humbug->validate(request => { method => 'GET', url => 'fake:ignore_shutdown' });
  my $start = Time::HiRes::time();
  ok !$humbug->close, 'close reports an unclean exit';
  ok reaped($pid), 'child killed and reaped';
  my $elapsed = Time::HiRes::time() - $start;
  ok $elapsed < 10, "bounded wait (${elapsed}s)";
};

subtest 'close after the child was killed' => sub {
  my $humbug = fake_humbug();
  my $pid = child_pid($humbug);
  kill 'KILL', $pid;
  my $start = Time::HiRes::time();
  my $clean;
  ok lives { $clean = $humbug->close }, 'close does not throw';
  ok !$clean, 'not a clean exit';
  ok reaped($pid), 'reaped';
  ok Time::HiRes::time() - $start < 3, 'promptly';
  ok lives { $humbug->close }, 'second close';
};

subtest 'close after the child exited on its own' => sub {
  my $humbug = fake_humbug();
  my $pid = child_pid($humbug);
  $humbug->validate(request => { method => 'GET', url => 'fake:closestdin' });  # exits 0 shortly after
  Time::HiRes::sleep(0.6);
  my $clean;
  ok lives { $clean = $humbug->close }, 'close does not throw';
  ok $clean, 'exit status 0 is a clean exit';
  ok reaped($pid), 'reaped';
};

subtest 'close after the child was reaped elsewhere' => sub {
  my $humbug = fake_humbug();
  my $pid = child_pid($humbug);
  kill 'KILL', $pid;
  waitpid $pid, 0;
  ok lives { $humbug->close }, 'close does not throw';
};

subtest 'validate after the child died' => sub {
  my $humbug = fake_humbug();
  kill 'KILL', child_pid($humbug);
  Time::HiRes::sleep(0.1);
  my $error = dies { $humbug->validate(request => { method => 'GET', url => 'https://x/' }) };
  is $error->kind, 'transport', 'transport failure, not a result';
  like $error->code, qr/^client\.(eof|broken_pipe)$/, 'eof or broken pipe';
};

subtest 'no zombies left behind' => sub {
  my $got = waitpid -1, POSIX::WNOHANG();
  is $got, -1, 'no children left to reap';
};

done_testing;
