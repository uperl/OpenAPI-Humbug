use Test2::V0 -no_srand => 1;
use 5.042;
use lib 't/lib';
use Time::HiRes ();
use OpenAPI::Humbug;
use FakeHumbug;

# each case: a fresh client, one command that fails fatally, then checks that the child
# was reaped and the client refuses further use
sub fatal ($behavior, $kind, $code, %options) {
  my $humbug = fake_humbug($options{mode} // 'ok', $options{new} ? $options{new}->%* : ());
  my $pid = $humbug->{pid};

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

subtest 'malformed JSON'           => sub { fatal badjson       => protocol => 'client.malformed_reply' };
subtest 'not an object'            => sub { fatal notobject     => protocol => 'client.malformed_reply' };
subtest 'mismatched id'            => sub { fatal mismatch      => protocol => 'client.id_mismatch' };
subtest 'string id'                => sub { fatal stringid      => protocol => 'client.id_mismatch' };
subtest 'null id on a result'      => sub { fatal nullid_result => protocol => 'client.id_mismatch' };
subtest 'unexpected type'          => sub { fatal badtype       => protocol => 'client.unexpected_reply' };
subtest 'result without result'    => sub { fatal noresult      => protocol => 'client.unexpected_reply' };
subtest 'error without code'       => sub { fatal baderror      => protocol => 'client.unexpected_reply' };
subtest 'two replies' => sub {
  my $humbug = fake_humbug();
  my $pid = $humbug->{pid};
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
subtest 'unexpected EOF'           => sub { fatal eof           => process  => 'client.eof' };
subtest 'EOF mid line'             => sub { fatal partial       => process  => 'client.eof' };

subtest 'child killed' => sub {
  my $error = fatal signal => process => 'client.eof';
  like $error->message, qr/signal 9/, 'says how it died';
};

subtest 'reply too long' => sub {
  fatal huge => protocol => 'client.reply_too_long', new => { max_reply_bytes => 1000 };
};

subtest 'broken pipe' => sub {
  fatal anything => process => 'client.broken_pipe', before => ['closestdin'], body => 'x' x (1024 * 1024);
};

subtest 'timeout' => sub {
  my $start = Time::HiRes::time();
  fatal hang => timeout => 'client.timeout', new => { timeout => 0.5 };
  my $elapsed = Time::HiRes::time() - $start;
  ok $elapsed < 5, "gave up promptly (${elapsed}s)";
};

subtest 'null id on an error is a sidecar error for the command in flight' => sub {
  my $humbug = fake_humbug();
  my $error = dies { $humbug->validate(request => { method => 'GET', url => 'fake:nullid_error' }) };
  is [ $error->kind, $error->code ], [ 'sidecar', 'protocol.line_too_long' ], 'sidecar error';
  ok $humbug->validate(request => { method => 'GET', url => 'https://x/' })->{valid}, 'still usable';
  ok $humbug->close, 'close';
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
  my $pid = $humbug->{pid};
  $humbug->validate(request => { method => 'GET', url => 'fake:ignore_shutdown' });
  my $start = Time::HiRes::time();
  ok !$humbug->close, 'close reports an unclean exit';
  ok reaped($pid), 'child killed and reaped';
  my $elapsed = Time::HiRes::time() - $start;
  ok $elapsed < 10, "bounded wait (${elapsed}s)";
};

subtest 'no zombies left behind' => sub {
  my $got = waitpid -1, POSIX::WNOHANG();
  is $got, -1, 'no children left to reap';
};

done_testing;
