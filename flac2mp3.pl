#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long;
use File::Find;
use Data::Dumper;
use File::Basename;

my $opt_no_genre;
my $opt_comment;
my $opt_catid;

# TODO fill this out
my %genreMap = (
    edm => 52,
    soundtrack => 24,
);

# this is a godsent page
# https://wiki.hydrogenaud.io/index.php?title=Tag_Mapping
# a lot of this may not work
# TODO escape potential 's
my %idLookup = (
    album => 'TALB',
    albumsort => 'TSOA',
    discsubtitle => 'TSST',
    grouping => 'TIT1',
    title => 'TIT2',
    titlesort => 'TSOT',
    subtitle => 'TIT3',
    subtitle => 'TIT3',
    albumartist => 'TPE2',
    albumartistsort => 'TSO2', # Maybe?
    artist => 'TPE1',
    artistsort => 'TSOP',
    arranger => 'TIPL=arranger',
    author => 'TEXT',
    composer => 'TCOM',
    conductor => 'TPE3',
    engineer => 'TIPL=engineer',
    djmixer => 'TIPL=DJ-mix',
    mixer => 'TIPL=mix',
    #performer => 'TMCL', # This produces some really weird tags
    producer => 'TIPL=producer',
    publisher => 'TPUB',
    label => 'TPUB',
    remixer => 'TPE4',
    discnumber => ['TPOS', sub {
        my $t = shift;
        my $totalkey = exists($t->{disctotal}) ? 'disctotal' : 'totaldiscs';
        return "$t->{discnumber}" if !exists($t->{$totalkey});
        return "$t->{discnumber}/$t->{$totalkey}";
    }],
    totaldiscs => undef,
    disctotal => undef,
    tracknumber => ['TRCK', sub {
        my $t = shift;
        my $totalkey = exists($t->{tracktotal}) ? 'tracktotal' : 'totaltracks';
        return "$t->{tracknumber}" if !exists($t->{$totalkey});
        return "$t->{tracknumber}/$t->{$totalkey}";
    }],
    totaltracks => undef,
    tracktotal => undef,
    #date => 'TDRC', # This is for id3v2.4
    date => 'TYER',
    originaldate => 'TDOR', # Also for 2.4 only
    isrc => 'TSRC',
    barcode => 'TXXX=BARCODE',
    catalog => ['TXXX=CATALOGNUMBER', sub { return tagmap_catalogid(shift, 'catalog'); } ],
    catalognumber => ['TXXX=CATALOGNUMBER', sub { return tagmap_catalogid(shift, 'catalognumber'); } ],
    catalogid => ['TXXX=CATALOGNUMBER', sub { return tagmap_catalogid(shift, 'catalogid'); } ],
    'encoded-by' => 'TENC',
    encoder => 'TSSE',
    encoding => 'TSSE',
    'encoder settings' => 'TSSE',
    media => 'TMED',
    replaygain_album_gain => 'TXXX=REPLAYGAIN_ALBUM_GAIN',
    replaygain_album_peak => 'TXXX=REPLAYGAIN_ALBUM_PEAK',
    replaygain_track_gain => 'TXXX=REPLAYGAIN_TRACK_GAIN',
    replaygain_track_peak => 'TXXX=REPLAYGAIN_TRACK_PEAK',
    genre => ['TCON', sub {
        return undef if ($opt_no_genre);

        my $genreName = shift->{genre};
        if (!exists($genreMap{lc($genreName)})) {
            # If no genre number exists, use the name
            return $genreName;
        }
        return $genreMap{$genreName};
    }],
    #mood => ['TMOO', sub {
    #}],
    bpm => 'TBPM',
    comment => ['COMM=Comment', sub {
        return undef if (defined($opt_comment) && $opt_comment eq "");
        return shift->{comment};
    }],
    copyright => 'TCOP',
    language => 'TLAN',
    script => 'TXXX=SCRIPT',
    lyrics => 'USLT',
    circle => 'TXXX=CIRCLE',
);
sub tagmap_catalogid {
        my $t = shift;
        my $own_tag_name = shift;
        return undef if (defined($opt_catid) && $opt_catid eq "");
        return $t->{$own_tag_name};
}

my $opt_genre;
my $opt_help;
GetOptions(
    "genre|g=s" => \$opt_genre,
    "no-genre|G" => \$opt_no_genre,
    "help|h" => \$opt_help,
    "catid=s" => \$opt_catid,
    "comment=s" => \$opt_comment,
) or die("Error in command line option");

if ($opt_help) {
    help();
}

if (scalar(@ARGV) != 2) {
    print("Bad arguments\n");
    usage();
}

my ($IDIR, $ODIR) = @ARGV;

if (!-e $ODIR) {
    mkdir $ODIR;
}

find({ wanted => \&iterFlac, no_chdir => 1 }, $IDIR);

sub iterFlac {
    # Return if file is not a file, or if it's not a flac
    return if (!-f || !/\.flac$/);

    my @required_tags = ("artist", "title", "album", "tracknumber");
    my $flac = $_;
    shellsan(\$flac);
    my $dest = "$ODIR/" . basename($flac);
    $dest =~ s/\.flac$/\.mp3/;
    my $tags = getFlacTags($flac);

    my $has_req_tags = 1;
    foreach (@required_tags) {
        if (!exists($tags->{lc($_)})) {
            $has_req_tags = 0;
            last;
        }
    }
    if (!$has_req_tags) {
        print("WARNING: File: '$flac' does not have all the required tags. Skipping\n");
        return;
    }
    
    argsToTags($tags);
    my $tagopts = tagsToOpts($tags);

    qx(flac -cd -- '$flac' | lame -V0 -S --vbr-new --add-id3v2 @$tagopts - '$dest');
}

sub argsToTags {
    my $argTags = shift;
    if (defined($opt_genre)) {
        $argTags->{genre} = $opt_genre;
    } elsif (defined($opt_comment) && $opt_comment ne "") {
        $argTags->{comment} = $opt_comment;
    } elsif (defined($opt_catid) && $opt_catid ne "") {
        $argTags->{catalognumber} = $opt_catid;
    }
}

sub tagsToOpts {
    my $tags = shift;
    my @tagopts;
    
    # TODO escape ' and =?
    foreach my $currKey (keys (%$tags)) {
        if (!exists($idLookup{$currKey})) {
            print("Tag: '$currKey' doesn't have a mapping, skipping\n");
            next;
        }
        my $tagName = $idLookup{$currKey};
        my $type = ref($tagName);
        if ($type eq "" && defined($tagName)) {
            my $tagCont = $tags->{$currKey};
            shellsan(\$tagCont);
            push(@tagopts, qq(--tv '$tagName=$tagCont'));
        } elsif ($type eq "ARRAY") {
            my $tagCont = $tagName->[1]->($tags);
            if (defined($tagCont)) {
                shellsan(\$tagCont);
                push(@tagopts, qq(--tv '$tagName->[0]=$tagCont'));
            }
        }

    }

    return \@tagopts;
}

sub getFlacTags {
    my $flac = shift;

    my %tags;
    my @tagtxt = qx(metaflac --list --block-type=VORBIS_COMMENT -- '$flac');
    foreach my $tagline (@tagtxt) {
        if ($tagline =~ /comment\[\d+\]:\s(.*?)=(.*)/) {
            $tags{lc($1)} = $2;
        }
    }
    return \%tags;
}

sub shellsan {
    ${$_[0]} =~ s/'/'\\''/g;
}

sub usage {
    print("Usage: flac2mp3.pl [-h | --help] [-g | --genre NUM] <input_dir> <output_dir>\n");
    exit 1;
}

sub help {
    my $h = <<EOF;
Usage:
    flac2mp3.pl [options] <input_dir> <output_dir>

    -h, --help          print this help text
    -g, --genre  NUM    force this genre as a tag (lame --genre-list)
    -G, --no-genre      ignore genre in flac file
    --catid     STRING  the catalog id to set (or "")
    --comment   STRING  the comment to set (or "")
EOF
    print($h);
    exit 0;
}

# vim: ts=4 sw=4 et sta
