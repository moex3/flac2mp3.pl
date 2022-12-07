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
my $opt_rg;

# TODO fill this out
my %genreMap = (
    edm => 52,
    soundtrack => 24,
);

# this is a godsent page
# https://wiki.hydrogenaud.io/index.php?title=Tag_Mapping
# https://picard-docs.musicbrainz.org/en/appendices/tag_mapping.html
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
    organization => 'TPUB',
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
    #date => 'TYER',
    date => [undef, sub {
        my $t = shift;
        my $date = $t->{date};
        if (length($date) == 4) { # Only year
            return "TYER=$date";
        }
        if (!($date =~ m/^\d{4}\.\d{2}\.\d{2}$/)) {
            print("Date format unknown: $date\n");
            exit 1;
        }
        $date =~ s/\./-/g;
        return "TDRL=$date"; # Release date
    }],
    originaldate => 'TDOR', # Also for 2.4 only
    'release date' => 'TDOR', # Also for 2.4 only
    isrc => 'TSRC',
    barcode => 'TXXX=BARCODE',
    catalog => ['TXXX=CATALOGNUMBER', sub { return tagmap_catalogid(shift, 'catalog'); } ],
    catalognumber => ['TXXX=CATALOGNUMBER', sub { return tagmap_catalogid(shift, 'catalognumber'); } ],
    catalogid => ['TXXX=CATALOGNUMBER', sub { return tagmap_catalogid(shift, 'catalogid'); } ],
    labelno => ['TXXX=CATALOGNUMBER', sub { return tagmap_catalogid(shift, 'labelno'); } ],
    'encoded-by' => 'TENC',
    encoder => 'TSSE',
    encoding => 'TSSE',
    'encoder settings' => 'TSSE',
    media => 'TMED',
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
    #replaygain_album_peak => 'TXXX=REPLAYGAIN_ALBUM_PEAK',
    #replaygain_album_gain => 'TXXX=REPLAYGAIN_ALBUM_GAIN',
    replaygain_track_gain => sub {
        return undef if (!$opt_rg);
        shift->{replaygain_track_gain} =~ /^(-?\d+\.\d+) dB$/;
        my $gain_db = $1;
        exit(1) if ($gain_db eq "");
        return "--replaygain-accurate --gain $gain_db";
    },

    #replaygain_album_gain => 'TXXX=REPLAYGAIN_ALBUM_GAIN',
    #replaygain_album_peak => 'TXXX=REPLAYGAIN_ALBUM_PEAK',
    #replaygain_track_gain => 'TXXX=REPLAYGAIN_TRACK_GAIN',
    #replaygain_track_peak => 'TXXX=REPLAYGAIN_TRACK_PEAK',
    script => 'TXXX=SCRIPT',
    lyrics => 'USLT',
    circle => 'TXXX=CIRCLE',
    event => 'TXXX=EVENT',
    discid => 'TXXX=DISCID',
    originaltitle => 'TXXX=ORIGINALTITLE',
);
sub tagmap_catalogid {
        my $t = shift;
        my $own_tag_name = shift;
        return undef if (defined($opt_catid) && $opt_catid eq "");
        return $t->{$own_tag_name};
}

my $opt_genre;
my $opt_help;
my @opt_tagreplace;
GetOptions(
    "genre|g=s" => \$opt_genre,
    "no-genre|G" => \$opt_no_genre,
    "replay-gain|r" => \$opt_rg,
    "help|h" => \$opt_help,
    "catid=s" => \$opt_catid,
    "comment=s" => \$opt_comment,
    "tagreplace|t=s" => \@opt_tagreplace,
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
    my $flacDir = substr($File::Find::name, length($IDIR));
    my $flac = $_;
    my $flac_o = $flac;
    shellsan(\$flac);
    my $dest = "$ODIR/" . $flacDir;
    #print("DEBUG: $dest\n");
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
        exit(1);
        return;
    }
    
    argsToTags($tags, $flac_o);
    my $tagopts = tagsToOpts($tags);

    #print("Debug: @$tagopts\n");
    shellsan(\$dest);
    my $cmd = "flac -cd -- '$flac' | lame -V0 -S --vbr-new -q 0 --add-id3v2 @$tagopts - '$dest'";
    #print("Debug - CMD: [$cmd]\n");
    qx($cmd);
    if ($? != 0) {
        exit(1);
    }
}

sub argsToTags {
    my $argTags = shift;
    my $fname = shift;
    $fname =~ s!^.*/!!;
    if (defined($opt_genre)) {
        $argTags->{genre} = $opt_genre;
    }
    if (defined($opt_comment) && $opt_comment ne "") {
        $argTags->{comment} = $opt_comment;
    }
    if (defined($opt_catid) && $opt_catid ne "") {
        $argTags->{catalognumber} = $opt_catid;
    }
    if (scalar @opt_tagreplace > 0) {
        foreach my $trepl (@opt_tagreplace) {
            $trepl =~ m!(.*?)/(.*?)=(.*)!;
            my ($freg, $tag, $tagval) = ($1, $2, $3);
            if ($fname =~ m!$freg!) {
                $argTags->{lc($tag)} = $tagval;
            }
        }
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
            # If tag name is defined and tag contents exists
            my $tagCont = $tags->{$currKey};
            shellsan(\$tagCont);
            push(@tagopts, qq(--tv '$tagName=$tagCont'));
        } elsif ($type eq "ARRAY") {
            my $tagCont = $tagName->[1]->($tags);
            my $tagKey = $tagName->[0];
            if (defined($tagCont)) {
                if (defined($tagKey)) {
                    shellsan(\$tagCont);
                    push(@tagopts, qq(--tv '$tagName->[0]=$tagCont'));
                } else {
                    if (ref($tagCont) eq 'ARRAY') {
                        # If we have an array of tags
                        foreach my $tC (@$tagCont) {
                            shellsan(\$tC);
                            push(@tagopts, qq(--tv '$tC'));
                        }
                    } else {
                        # If we have only one 
                        shellsan(\$tagCont);
                        push(@tagopts, qq(--tv '$tagCont'));
                    }
                }
            }
        } elsif ($type eq 'CODE') {
            # If we have just a code reference
            # do not assume, that this is a tag, rather a general cmd opt
            my $opt = $tagName->($tags);
            if (defined($opt)) {
                shellsan(\$opt);
                push(@tagopts, qq($opt));
            }
        }

    }

    return \@tagopts;
}

sub getFlacTags {
    my $flac = shift;

    my %tags;
    my @tagtxt = qx(metaflac --list --block-type=VORBIS_COMMENT -- '$flac');
    if ($? != 0) {
        exit(1);
    }
    foreach my $tagline (@tagtxt) {
        if ($tagline =~ /comment\[\d+\]:\s(.*?)=(.*)/) {
            if ($2 eq '') {
                print("Empty tag: $1\n");
                next;
            }
            $tags{lc($1)} = $2;
        }
    }
    return \%tags;
}

sub shellsan {
    ${$_[0]} =~ s/'/'\\''/g;
}

sub usage {
    print("Usage: flac2mp3.pl [-h | --help] [-r] [-g | --genre NUM] <input_dir> <output_dir>\n");
    exit 1;
}

sub help {
    my $h = <<EOF;
Usage:
    flac2mp3.pl [options] <input_dir> <output_dir>

    -h, --help          print this help text
    -g, --genre  NUM    force this genre as a tag (lame --genre-list)
    -G, --no-genre      ignore genre in flac file
    -r, --replay-gain   use replay gain values
    --catid     STRING  the catalog id to set (or "")
    --comment   STRING  the comment to set (or "")
    -t --tagreplace STR Replace flac tags for a specific file only
                        Like -t '02*flac/TITLE=Some other title'
EOF
    print($h);
    exit 0;
}

# vim: ts=4 sw=4 et sta
