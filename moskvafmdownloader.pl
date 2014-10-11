#!/usr/bin/perl
use strict;
use IO::Pipe;
use LWP::UserAgent;
#use MPEG::Audio::Frame 0.04;
use constant WIN => 'win';
use constant NIX => 'nix';
use constant MAX_RETRIES => 5;
use constant DOWNLOAD_ERR => 0;
use constant DOWNLOAD_OK => 1;
use vars qw ($dir $dirTMP $os);
my ($station, $dt, $minutes, $files) = @ARGV;
if ($minutes eq "" || $dt eq "" || $station eq "") {
    print <<USAGE;

Usage: $0 STATION START DURATION [FILES]

    STATION station number
    START date and time to start. Format: YYYY/MM/DD/HHII
    DURATION duration in minutes
    FILES amount of files to be assembled in one piece

    Example: $0 4023 2010/12/01/0710 230 5

USAGE
}
else {
    $os = ($^O eq 'MSWin32' ? WIN : NIX);
    $dt =~ /^(\d{4}).(\d{2}).(\d{2}).(\d{2})(\d{2})$/;
    my ($year, $month, $day, $hour, $minute) = ($1, $2, $3, $4, $5);
    if ($year eq "" || $month eq "" || $day eq "" || $hour eq "" || $minute eq "") {
        print "Wrong START date format\n";
    }
    else {
        if ($minutes !~ /^\d+$/) {
            print "Wrong DURATION format\n";
        }
        else {
            my @assemble;
            $dir = "$year$month$day"."_$station";
            $dirTMP = "$dir/TMP";
            mkdir $dir, 0755;
            mkdir $dirTMP, 0755;
            my $p2c = new IO::Pipe;
            if (my $pid = fork()) {# Parent - download
                $p2c->writer();
                $p2c->autoflush(1);
                for (my $i = 0; $i < $minutes; $i++) {
                    ($day, $hour, $minute) = getNextMinute($day, $hour, $minute);
                    my $res = download("http://dt.moskva.fm/files/$station/mp4/$year/$month/$day/", "$hour$minute.mp4");
                    if ($res == DOWNLOAD_OK) {
                        my $size = -s "./$dirTMP/$hour$minute.mp3";
                        if ($size < 959000) {
                            $p2c->print("$hour$minute\n");
                        }
                        $assemble[$i] = "$hour$minute.mp3";
                    } else {
                        $assemble[$i] = "$hour$minute";
                    }
                    $minute++;
                }
                $p2c->print("\n");
                waitpid($pid, 0);
            } else { # Child - decode
                $p2c->reader();
                print "child waits...\n";
                while(<$p2c>) {
                    $_ =~ s/\n//;
                    exit 0 if $_ eq '';
                    decode($_);
                }
            }
            my $done = 0;
            if ($files =~ /^\d+$/) {
                my $outFileName;
                my $j = 1;
                for (my $i = 0; $i < $minutes; $i+=$files) {
                    my ($params, $end);
                    if ($i + $files < $minutes) {
                        $end = ($i + $files - 1);
                    }
                    else {
                        $end = $minutes - 1;
                    }
                    $outFileName = sprintf ("out_%06d.mp3", $j);
                    if ($os eq NIX) {
                        map {$params .= "$dirTMP/$_ " if $_ !~ /^\d{4}$/} @assemble[$i..$end];
                        if ($params ne '') {
                            `mp3cut -o $dir/$outFileName $params`;
                        }
                    } else {
                        map {$params .= "$dirTMP/$_ + " if $_ !~ /^\d{4}$/} @assemble[$i..$end - 1];
                        $params .= "$dirTMP/$assemble[$end]" if $assemble[$end] ne '';
                        if ($params ne '') {
                            my $command = "$params $dir/$outFileName\n";
                            $command =~ s/\//\\/g;
                            $command = "copy /b $command";
                            print "$command\n";
                            `$command`;
                        }
                    }
                    $j++;
                }
            }
            print "checking errors... ";
            my @errors;
            foreach my $file (@assemble) {
                my $size = -s "./$dirTMP/$file";
                if ($size < 959000) {
                    push @errors, $file;
                }
            }
            my $cnt = @errors;
            if ($cnt == 0) {
                print "$cnt\n";
            } else {
                my $files = '';
                map{$files .= "$_ "} @errors;
                print "$cnt out of ".(scalar @assemble).":\n$files\n";
            }
        }
    }
    print "Done\n";
}

################################################################################
sub getNextMinute {
    my ($day, $hour, $minute) = @_;
    if ($minute >= 60) {
        $hour++;
        $minute = 0;
    }
    if ($hour >= 24) {
        $day++;
        $hour = 0;
    }
    if ($day < 10) {
        $day = "0".($day+0);
    }
    if ($hour < 10) {
        $hour = "0".($hour+0);
    }
    if ($minute < 10) {
        $minute = "0".($minute+0);
    }
    return ($day, $hour, $minute);
}

sub getFileSize{
    my ($path, $file) = @_;
    my $ua = new LWP::UserAgent;
    $ua->agent("Mozilla/5.0");
    my $req = new HTTP::Request 'HEAD' => $path.$file;
    $req->header('Accept' => 'text/html');
    my $res = $ua->request($req);
    if ($res->is_success) {
        my $headers = $res->headers;
        print "'$file' size = ".$headers->content_length."\n";
        return $headers->content_length;
    }
    return -1;
}

sub download {
    my ($path, $file) = @_;
    my $url = "$path$file";
    print "Downloading '$url'\n";
    my $return = DOWNLOAD_ERR;
    my $size = -s "$dirTMP/$file";
    my $fileSize = getFileSize($path, $file);
    if ($size != $fileSize) {
        print "'$file' expected size: $fileSize\n";
        my $ua = LWP::UserAgent->new();
        $ua->agent("");
        $ua->timeout(30);
        $ua->env_proxy;
        my $tries = MAX_RETRIES;
        my $expectedLength;
        my $bytesReceived = 0;
        do {
            $expectedLength = 0;
            $bytesReceived = 0;
            open (OUTFILE, ">$dirTMP/$file") || die("output error: $!\n");
            binmode(OUTFILE);
            my $res = $ua->request(HTTP::Request->new(GET => $url),
                sub {
                    my($chunk, $res) = @_;
                    $bytesReceived += length($chunk);
                    unless (defined $expectedLength) {
                        $expectedLength = $res->content_length || 0;
                    }
                    if ($expectedLength) {
                        printf "%d%% - ", 100 * $bytesReceived / $expectedLength;
                    }
                    print OUTFILE $chunk;
                }
            );
            close(OUTFILE);
            if ($bytesReceived == $fileSize) {
                print "'$file' download ok\n";
                $return = DOWNLOAD_OK;
            } else {
                print "'$file' download failed; bytes received: $bytesReceived; retry ($tries)\n";
                sleep(1);
                $tries--;
            }
        } while ($tries > 0 && $bytesReceived != $fileSize);
    } else {
        print "'$file' exists\n";
        $return = DOWNLOAD_OK;
    }
    return $return;
}

sub decode {
    my $file = shift;
    print "'$file.mp4' decoding...\n";
    `faad -q -o - ./$dirTMP/$file.mp4 | lame --silent - ./$dirTMP/$file.mp3`;
    if ($os eq NIX) {
        `mp3cut -o ./$dirTMP/cut_$file.mp3 -t 00:00-01:00 ./$dirTMP/$file.mp3`;
        `mv ./$dirTMP/cut_$file.mp3 ./$dirTMP/$file.mp3`;
    } else {
        open (OUTFILE, ">$dirTMP/cut_$file.mp3") || die("output error: $!\n");
        binmode(OUTFILE);
        open (INFILE, "$dirTMP/$file.mp3") || die("in error: $!\n");
        binmode(INFILE);
        my $len = 0;
        my $frame;
        do {
            $frame = MPEG::Audio::Frame->read(\*INFILE);
            if ($frame && $len < 60) {
                $len += $frame->seconds;
                print OUTFILE $frame->asbin;
            }
        } while ($len < 60);
        close(OUTFILE);
        close(INFILE);
        rename "$dirTMP/cut_$file.mp3", "$dirTMP/$file.mp3";
    }
    print "'$file.mp4' decoded\n";
}
