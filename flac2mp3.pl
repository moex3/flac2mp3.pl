#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long;
use File::Find;
use Data::Dumper;
use File::Basename;
use File::Temp qw/ tempfile /;

my $opt_no_genre;
my $opt_comment;
my $opt_catid;
my $opt_rg;
my $opt_embedcover;

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
#
# Format is:
#  Vorbis tag string => Mp3 tag value
#  where mp3 tag value may be:
#   undef -> Skip this tag
#   A string -> Use this as the mp3 tag, and use the vorbis tag value as value
#   code -> Execute this function. This should return an array, where [0] is the tag, [1] is the value.
#   An array (str, str) -> [0] is the mp3 tag to use, [1] is the value prefix
#   An array (str, code) -> [0] is the mp3 tag to use, [1] is a function that is executed, and the result is the tag value
#  The code-s here will be called with the flac tags hashmap
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
    # arranger => ['TIPL', 'arranger:'],
    arranger => ['TXXX', 'ARRANGER:'],
    author => 'TEXT',
    composer => 'TCOM',
    conductor => 'TPE3',
    engineer => ['TIPL', 'engineer:'],
    djmixer => ['TIPL', 'DJ-mix:'],
    mixer => ['TIPL', 'mix:'],
    # performer => ['TMCL', "instrument:"], # Should be like this, but mid3v2 says it doesn't have this tag.
    performer => ['TXXX', "PERFORMER:"],
    producer => ['TIPL', 'producer:'],
    publisher => 'TPUB',
    organization => 'TPUB',
    label => 'TPUB',
    remixer => 'TPE4',
    discnumber => ['TPOS', sub {
        my $t = shift;
        my $totalkey = exists($t->{disctotal}) ? 'disctotal' : 'totaldiscs';
        return "$t->{discnumber}[0]" if !exists($t->{$totalkey});
        return "$t->{discnumber}[0]/$t->{$totalkey}[0]";
    }],
    totaldiscs => undef,
    disctotal => undef,
    tracknumber => ['TRCK', sub {
        my $t = shift;
        my $totalkey = exists($t->{tracktotal}) ? 'tracktotal' : 'totaltracks';
        return "$t->{tracknumber}[0]" if !exists($t->{$totalkey});
        return "$t->{tracknumber}[0]/$t->{$totalkey}[0]";
    }],
    totaltracks => undef,
    tracktotal => undef,
    #date => 'TDRC', # This is for id3v2.4
    #date => 'TYER',
    date => sub {
        my $t = shift;
        my $date = $t->{date}[0];
        if (length($date) == 4) { # Only year
            return ["TYER", "$date"];
        }
        if (!($date =~ m/^\d{4}[\.-]\d{2}[\.-]\d{2}$/)) {
            print("Date format unknown: $date\n");
            exit 1;
        }
        $date =~ s/[\.-]/-/g;
        return ["TDRL", "$date"]; # Release date
    },
    originaldate => 'TDOR', # Also for 2.4 only
    'release date' => 'TDOR', # Also for 2.4 only
    isrc => 'TSRC',
    barcode => ['TXXX', 'BARCODE:'],
    catalog => ['TXXX', sub { return "CATALOGNUMBER:" . tagmap_catalogid(shift, 'catalog'); } ],
    catalognumber => ['TXXX', sub { return "CATALOGNUMBER:" . tagmap_catalogid(shift, 'catalognumber'); } ],
    catalogid => ['TXXX', sub { return "CATALOGNUMBER:" . tagmap_catalogid(shift, 'catalogid'); } ],
    labelno => ['TXXX', sub { return "CATALOGNUMBER:" . tagmap_catalogid(shift, 'labelno'); } ],
    #'encoded-by' => 'TENC',
    #encoder => 'TSSE',
    #encoding => 'TSSE',
    #'encoder settings' => 'TSSE',
    media => 'TMED',
    genre => ['TCON', sub {
        return undef if ($opt_no_genre);

        my $genreName = shift->{genre}[0];
        if (!exists($genreMap{lc($genreName)})) {
            # If no genre number exists, use the name
            return $genreName;
        }
        return $genreMap{$genreName};
    }],
    #mood => ['TMOO', sub {
    #}],
    bpm => 'TBPM',
    comment => ['COMM', sub {
        return undef if (defined($opt_comment) && $opt_comment eq "");
        return "Comment:" . shift->{comment}[0];
    }],
    copyright => 'TCOP',
    language => 'TLAN',
    #replaygain_album_peak => 'TXXX=REPLAYGAIN_ALBUM_PEAK',
    #replaygain_album_gain => 'TXXX=REPLAYGAIN_ALBUM_GAIN',
    replaygain_track_gain => sub {
        print("EEEEEEERRRRRRRRROOOOOOOOOORRRRRRRRRRRE FIXXXXXXXXXXXX THIIIIIIIIISSSSSSSS\n");
        exit(1);
        return undef if (!$opt_rg);
        shift->{replaygain_track_gain}[0] =~ /^(-?\d+\.\d+) dB$/;
        my $gain_db = $1;
        exit(1) if ($gain_db eq "");
        return "--replaygain-accurate --gain $gain_db";
        # TODO this lulw
    },

    #replaygain_album_gain => 'TXXX=REPLAYGAIN_ALBUM_GAIN',
    #replaygain_album_peak => 'TXXX=REPLAYGAIN_ALBUM_PEAK',
    #replaygain_track_gain => 'TXXX=REPLAYGAIN_TRACK_GAIN',
    #replaygain_track_peak => 'TXXX=REPLAYGAIN_TRACK_PEAK',
    script => ['TXXX', 'SCRIPT:'],
    lyrics => 'USLT',
    lyricist => 'TEXT',
    circle => ['TXXX', 'CIRCLE:'],
    event => ['TXXX', 'EVENT:'],
    discid => ['TXXX', 'DISCID:'],
    originaltitle => ['TXXX', 'ORIGINALTITLE:'],
    origin => ['TXXX', 'ORIGIN:'],
    origintype => ['TXXX', 'ORIGINTYPE:'],
);
sub tagmap_catalogid {
        my $t = shift;
        my $own_tag_name = shift;
        return undef if (defined($opt_catid) && $opt_catid eq "");
        return $t->{$own_tag_name}[0];
}

my $opt_genre;
my $opt_help;
my @opt_tagreplace;
my $opt_cbr = 0;
GetOptions(
    "genre|g=s" => \$opt_genre,
    "no-genre|G" => \$opt_no_genre,
    "replay-gain|r" => \$opt_rg,
    "help|h" => \$opt_help,
    "catid=s" => \$opt_catid,
    "comment=s" => \$opt_comment,
    "cover=s" => \$opt_embedcover,
    "tagreplace|t=s" => \@opt_tagreplace,
    "320|3" => \$opt_cbr,
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
    #foreach (%$tags) {
    #print("Copying tag '$_->[0]=$_->[1]'\n");
    #}
    my $tagopts = tagsToOpts($tags);

    #print("Debug: @$tagopts\n");
    shellsan(\$dest);
    my $cmd;
    if ($opt_cbr) {
        $cmd = "flac -cd -- '$flac' | lame -S -b 320 -q 0 --add-id3v2 - '$dest'";
    } else {
        $cmd = "flac -cd -- '$flac' | lame -S -V0 --vbr-new -q 0 --add-id3v2 - '$dest'";
    }
    #print("Debug - CMD: [$cmd]\n");
    qx($cmd);
    if ($? != 0) {
        exit(1);
    }

    my $mid3v2TagLine = "";
    #print(Dumper(\@$tagopts));
    # Add tags with mid3v2 instead of lame to better support multiple tag values
    foreach my $tagItem (@$tagopts) {
        $mid3v2TagLine = $mid3v2TagLine . $tagItem . " ";
    }
    #print(Dumper(\$mid3v2TagLine));

    my $mid3v2TagCmd = "mid3v2 $mid3v2TagLine -- '$dest'";
    #print("Mid3V2 Debug - CMD: [$mid3v2TagCmd]\n");
    qx($mid3v2TagCmd);
    if ($? != 0) {
        print("ERROR: At mid3v2 tag set\n");
        exit(1);
    }

    embedImageFromFlac($flac, $dest);
}

sub getMimeType {
    my $file = shift;
    shellsan(\$file);
    my $mime = qx(file -b --mime-type '$file');
    chomp($mime);
    return $mime;
}

sub embedImageFromFlac {
    my $flac = shift;
    my $mp3 = shift;

    return if ($opt_embedcover eq "");
    if ($opt_embedcover ne "") {
        my $cmime = getMimeType($opt_embedcover);
        qx(mid3v2 -p '${opt_embedcover}:cover:3:$cmime' -- '$mp3');
        return;
    }

    # I can't get the automatic deletion working :c
    my (undef, $fname) = tempfile();
    # Export image from flac
    qx(metaflac --export-picture-to='$fname' -- '$flac');
    if ($? != 0) {
        # Probably no image
        unlink($fname);
        return;
    }
    # Extract mime type too
    my $pinfo = qx(metaflac --list --block-type=PICTURE -- '$flac');
    $pinfo =~ m/MIME type: (.*)/;
    my $mimeType = $1;

    # Add image to mp3
    qx(mid3v2 -p '${fname}:cover:3:$mimeType' -- '$mp3');
    unlink($fname);
}

sub argsToTags {
    my $argTags = shift;
    my $fname = shift;
    $fname =~ s!^.*/!!;
    if (defined($opt_genre)) {
        $argTags->{genre} = [$opt_genre];
    }
    if (defined($opt_comment)) {
        if ($opt_comment eq "") {
            delete($argTags->{comment});
        } else {
            $argTags->{comment} = [$opt_comment];
        }
    }
    if (defined($opt_catid) && $opt_catid ne "") {
        $argTags->{catalognumber} = [$opt_catid];
    }
    if (scalar @opt_tagreplace > 0) {
        foreach my $trepl (@opt_tagreplace) {
            $trepl =~ m!(.*?)/(.*?)=(.*)!;
            my ($freg, $tag, $tagval) = ($1, $2, $3);
            if ($fname =~ m!$freg!) {
                $argTags->{lc($tag)} = ($tagval);
            }
        }
    }
}

sub mergeDupeTxxx {
    # Merge tags together, that we can't have multiples of
    # Like TXXX with same key

    my $tagsArr = shift;

    for (my $i = 0; $i < scalar @$tagsArr; $i++) {
        if (lc($tagsArr->[$i]->[0]) ne "txxx") {
            next;
        }

        $tagsArr->[$i]->[1] =~ m/^(.*?):(.*)$/;
        my $txkeyFirst = $1;
        my $txvalFirst = $2;

        for (my $j = $i + 1; $j < scalar @$tagsArr; $j++) {
            next if (lc($tagsArr->[$j]->[0]) ne "txxx");
            $tagsArr->[$j]->[1] =~ m/^(.*?):(.*)$/;
            my $txkeySecond = $1;
            my $txvalSecond = $2;

            next if ($txkeyFirst ne $txkeySecond);
            # TXXX keys are equal, append the second to the first, and delete this entry
            $tagsArr->[$i]->[1] .= ';' . $txvalSecond;
            #print("DDDDDDDDDDDDD: Deleted $j index $txkeySecond:$txvalSecond\n");
            splice(@$tagsArr, $j, 1);
        }
    }
}

sub tagsToOpts {
    my $tags = shift;
    my @tagopts;

    # TODO escape stuff?
    foreach my $currKey (keys (%$tags)) {
        if (!exists($idLookup{$currKey})) {
            print("Tag: '$currKey' doesn't have a mapping, skipping\n");
            next;
        }
        my $tagMapping = $idLookup{$currKey};
        my $type = ref($tagMapping);
        if ($type eq "" && defined($tagMapping)) {
            # If tag name is defined and tag contents exists (aka not silenced)
            foreach my $tagCont (@{$tags->{$currKey}}) {
                shellsan(\$tagCont);
                push(@tagopts, ["$tagMapping", "$tagCont"]);
            }
        } elsif ($type eq "ARRAY") {
            my $mapKey = $tagMapping->[0];
            my $mapCont = $tagMapping->[1];
            my $mapContType = ref($mapCont);
            if (not defined($mapCont)) {
                print("WHUT???\n");
                exit(1);
            }

            if ($mapContType eq "") {
                foreach my $tagValue (@{$tags->{$currKey}}) {
                    shellsan(\$tagValue);
                    push(@tagopts, ["$mapKey", "$mapCont$tagValue"]);
                }
            } elsif ($mapContType eq "CODE") {
                my $tagValue = $mapCont->($tags);
                shellsan(\$tagValue);
                push(@tagopts, ["$mapKey", "$tagValue"]);
            }
        } elsif ($type eq 'CODE') {
            # If we have just a code reference
            # do not assume, that this is a tag, rather a general cmd opt
            #my $opt = $tagName->($tags);
            #if (defined($opt)) {
            #shellsan(\$opt);
            #push(@tagopts, qq($opt));
            #}

            my $codeRet = $tagMapping->($tags);
            my $mapKey = $codeRet->[0];
            my $mapCont = $codeRet->[1];
            shellsan(\$mapCont);
            push(@tagopts, ["$mapKey", "$mapCont"]);
        }
    }

    mergeDupeTxxx(\@tagopts);

    # Convert the tag array into an array of string to use with mid3v2
    my @tagoptsStr;

    foreach (@tagopts) {
        push(@tagoptsStr, qq('--$_->[0]' '$_->[1]'));
    }

    return \@tagoptsStr;
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
            if (not exists($tags{lc($1)})) {
                @{$tags{lc($1)}} = ($2);
            } else {
                push(@{$tags{lc($1)}}, $2);
            }
        }
    }
    return \%tags;
}

sub shellsan {
    ${$_[0]} =~ s/'/'\\''/g;
}

sub usage {
    print("Usage: flac2mp3.pl [-h | --help] [-r] [-3] [-g | --genre NUM] <input_dir> <output_dir>\n");
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
    --cover     STRING  Use this image as cover (or "" to not copy from flac)
    -t --tagreplace STR Replace flac tags for a specific file only
                        Like -t '02*flac/TITLE=Some other title'
    -3, --320           Convert into CBR 320 instead into the default V0
EOF
    print($h);
    exit 0;
}

# vim: ts=4 sw=4 et sta
