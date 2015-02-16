#!/usr/bin/perl
use strict;
use warnings;
use Cwd;
use Getopt::Long;

# Hash used to perform reverse translations
my %rev_codon_table = (
	S => qr/((AG[C|T])|(TC.))/,
	F => qr/TT[T|C]/,
	L => qr/((TT[A|G])|(CT.))/,
	Y => qr/TA[T|C]/,
	C => qr/TG[T|C]/,
	W => qr/TGG/,
	P => qr/CC./,
	H => qr/CA[T|C]/,
	Q => qr/CA[A|G]/,
	R => qr/((AG[A|G])|(CG.))/,
	I => qr/AT[T|C|A]/,
	M => qr/ATG/,
	T => qr/AC./,
	N => qr/AA[T|C]/,
	K => qr/AA[A|G]/,
	V => qr/GT./,
	A => qr/GC./,
	D => qr/GA[T|C]/,
	E => qr/GA[A|G]/,
	G => qr/GG./,
	X => qr/.../,
);

# Default settings
my $model = "YN";
my $bin_size = 0.05;
my $match_length_threshold = 300; # Nucleotides

# Range for Ks plot
my $ks_min = 0;
my $ks_max = 3;
my $exclude_zero;

# Check that dependencies can be found in user's PATH
my $r = check_path_for_exec("R");
my $blat = check_path_for_exec("blat");
my $transdecoder = check_path_for_exec("TransDecoder");
my $kaks_calculator = check_path_for_exec("KaKs_Calculator");

# Parse command line options
GetOptions(
	"model|m:s" => \$model,
	"ks_min:f" => \$ks_min,
	"ks_max:f" => \$ks_max,
	"bin_size|b:f" => \$bin_size,
	"exclude_zero|x" => \$exclude_zero,
	"match_length_threshold|t:i" => \$match_length_threshold,
	"help|h" => \&help,
	"usage" => \&usage
);

# Error check input
my $transcriptome = shift;
#die "You must specify a transcriptome for input.\n" if (!defined($transcriptome));
#die "Could not locate '$transcriptome'.\n" if (!-e $transcriptome);
die "You must specify a transcriptome for input.\n".&usage if (!defined($transcriptome));
die "Could not locate '$transcriptome'.\n".&usage if (!-e $transcriptome);

# Determine working directory and root of filename
(my $input_dir = $transcriptome) =~ s/(.*\/).*/$1/;
(my $input_root = $transcriptome) =~ s/.*\/(.*)\..*/$1/;

if ($input_dir eq $input_root) {
	$input_dir = getcwd()."/";
	$input_root =~ s/(.*)\..*/$1/;
}

chdir($input_dir);

# Run TransDecoder
print "\nRunning TransDecoder on '$transcriptome'...\n";
my $transdecoder_out_dir = "ks-plot-transdecoder";
system("$transdecoder -t $transcriptome --workdir $transdecoder_out_dir") && die;

# Clean up unneeded files
chdir($transdecoder_out_dir);
unlink(glob("*"));
rmdir($transdecoder_out_dir);
chdir("..");

print "Completed TransDecoder.\n\n";

# Run blat
print "Running self blat...\n";
system("$blat $transcriptome.transdecoder.pep $transcriptome.transdecoder.pep -prot -out=pslx $transcriptome.pslx -noHead") && die;
print "Completed self blat.\n\n";

# Load transcriptome
my %align = parse_fasta("$transcriptome.transdecoder.mRNA");

print "Parsing self blat output...\n";

my $id = 0;
my @output;
my %queries;
my %matches;
open(my $blat_out, "<", "$transcriptome.pslx");
while (my $line = <$blat_out>) {
	chomp($line);

	# Split the line on tabs and extract the information we want
	my @line = split("\t", $line);
	my ($query_name, $match_name, $query_align, $match_align) = 
		($line[9], $line[13], $line[21], $line[22]);
	
	# Check if requirements are met
	if ($query_name ne $match_name) {
		# Reverse translate amino acids to their corresponding nucleotides

		my @query_align =  split(",", $query_align);
		my @match_align =  split(",", $match_align);

		my $query_nuc_align = $align{$query_name};
		my $match_nuc_align = $align{$match_name};

		my $trans_query_align;
		foreach my $align (@query_align) {
			$trans_query_align .= reverse_translate({"DNA" => $query_nuc_align, "PROT" => $align});
		}

		my $trans_match_align;
		foreach my $align (@match_align) {
			$trans_match_align .= reverse_translate({"DNA" => $match_nuc_align, "PROT" => $align});
		}

		$query_align = $trans_query_align;
		$match_align = $trans_match_align;

		if (length($query_align) >= $match_length_threshold && length($match_align) >= $match_length_threshold) {

			# Check that the match hasn't already been extracted
			if (!exists($queries{"$match_name-$query_name"})) {

				# Remove nucleotides to make length a multiple of 3
				die "WHUT?\n" if (length($query_align) % 3 != 0);

				my $name = "q_$query_name"."_t_$match_name";
				my $pair = {'QUERY_ALIGN' => $query_align,
							'MATCH_ALIGN' => $match_align,
							'LENGTH' => length($query_align)};

				# Check if there is already a match between these two sequences
				# if there is a match, the longer length one will be output
				if (exists($matches{$name})) {
					my $current_length = $matches{$name}->{'LENGTH'};
					if ($current_length <= length($query_align)) {
						$matches{$name} = $pair;
					}
				}
				else {
					$matches{$name} = $pair;
				}
				$queries{"$query_name-$match_name"}++;
			}
		}
	}
}

foreach my $key (sort { $a cmp $b} keys %matches) {
	my $pair = $matches{$key};
	push(@output, ">$key\n");
	push(@output, "$pair->{QUERY_ALIGN}\n");
	push(@output, "$pair->{MATCH_ALIGN}\n\n");
	$id++;
}

die "No blat hits met the requirements.\n\n" if ($id == 0);
print "Completed parsing blat output, $id blat hit(s) met the requirements.\n\n";

open(my $output_file, ">", "$transcriptome.atx");
print {$output_file} @output;
close($output_file);

# Run KaKs_Calculator to get Ks values
print "Running KaKs_Calculator...\n";
system("$kaks_calculator -i $transcriptome.atx -o $transcriptome.kaks -m $model >/dev/null") && die;
print "Completed KaKs_Calculator.\n\n";

# Open KaKs_Calculator output, parse Ks values and convert to .csv for R
open(my $ka_ks_calculator_output, "<", "$transcriptome.kaks");
open(my $ks_csv, ">", "$transcriptome.csv");
while (my $line = <$ka_ks_calculator_output>) {
	chomp($line);
	my @line = split(/\s+/, $line);

	# Skip first line containing headers
	if ($. == 1) {
		print {$ks_csv} "ks\n";
		next;
	}

	my $ks = $line[3];
	$ks = 0 if ($ks eq "NA");
	next if ($ks == 0 && $exclude_zero);

	print {$ks_csv} "$ks\n"
}
close($ks_csv);
close($ka_ks_calculator_output);

# Create PDF plot of output
print "Creating Ks plot in R...\n";
system("echo \"pdf(file='$transcriptome-ks.pdf'); 
	data=read.csv('$transcriptome.csv'); 
	dat1 <- data\\\$ks[data\\\$ks < $ks_max]; 
	hist(dat1, breaks=seq($ks_min,$ks_max,by=$bin_size), 
		main=expression(paste('K'[s], ' Plot for $transcriptome')), 
		xlab=expression(paste('Pairwise', ' K'[s])), axes=T);\" | $r --no-save") && die;
print "\nCompleted Ks plot.\n";

sub reverse_translate {
	my $settings = shift;

	my $dna = $settings->{'DNA'};
	my $prot = $settings->{'PROT'};

	my $regex;
	foreach my $index (0 .. length($prot) - 1) {
		my $char = substr($prot, $index, 1);
		$regex .= $rev_codon_table{$char};
	}

	my $translation;
	if ($dna =~ /($regex)/) {
		$translation = $1;
	}
	elsif (reverse($dna) =~ /($regex)/) {
		$translation = $1;
	}
	else {
		die "Protein sequence could not be reverse translated.\n";
	}

	return $translation;
}

sub check_path_for_exec {
	my $exec = shift;
	
	my $path = $ENV{PATH}.":."; # include current directory as well
	my @path_dirs = split(":", $path);

	my $exec_path;
	foreach my $dir (@path_dirs) {
		$dir .= "/" if ($dir !~ /\/$/);
		$exec_path = $dir.$exec if (-e $dir.$exec);
	}

	die "Could not find the following executable: '$exec'. This script requires this program in your path.\n" if (!defined($exec_path));
	return $exec_path;
}

sub parse_fasta {
	my $filename = shift;

	my %align;
	open(my $alignment_file, '<', $filename) 
		or die "Could not open '$filename': $!\n";
	chomp(my @data = <$alignment_file>);
	close($alignment_file);
	
	my $taxon;
	foreach my $line (@data) {
		if ($line =~ /^>(\S+)/) {
			$taxon = $1;
		}
		else {
			$taxon =~ s/-/_/g;
			$align{$taxon} .= $line;
		}
	}
	return %align;
}

sub usage {
	return "Usage: perl $0 [TRANSCRIPTOME] [OPTIONS]...\n";
}

sub help {
print <<EOF; 
@{[usage()]}
Generate a Ks plot for a given transcriptome in fasta format

  -m, --model                       model used by KaKs_Calculator to determine Ks (default: YN)
  -t, --match_length_threshold      the minimum number of basepairs the matching sequences must be (default: 300 bp)
  -x, --exclude_zero                used to exclude Ks = 0 from plot, useful for Trinity transcriptomes
  -b, --bin_size                    size of bins used in histogram of Ks plot
  --ks_min                          lower boundary for x-axis of Ks plot (default: Ks = 0)
  --ks_max                          upper boundary for x-axis of Ks plot (default: Ks = 3)
  -h, --help                        display this help and exit

Examples:
  perl $0 assembly.fa -b 0.01               generates a Ks (YN model) plot from [0, 3] using a bin size of 0.01, and contigs 
                                                    with at least 300 bp of homologous sequence

  perl $0 assembly.fa -x -m NG              generates a Ks (NG model) plot from (0, 3] using a bin size of 0.05, and contigs 
                                                    with at least 300 bp of homologous sequence

  perl $0 assembly.fa --ks_max 5 -t 500     generates a Ks (YN model) plot from [0, 5] using a bin size of 0.01, and contigs 
                                                    with at least 500 bp of homologous sequence

Mail bug reports and suggestions to <noah.stenz.github\@gmail.com>
EOF
exit(0);
}
