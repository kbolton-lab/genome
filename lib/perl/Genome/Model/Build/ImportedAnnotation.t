use strict;
use warnings;

BEGIN {
    $ENV{UR_DBI_NO_COMMIT} = 1;
    $ENV{UR_USE_DUMMY_AUTOGENERATED_IDS} = 1;
}

use above "Genome";
use Test::More tests => 43;
use Data::Dumper;
use Genome::Test::Factory::AnalysisProject;

Genome::Report::Email->silent();

use_ok('Genome::Model::Build::ImportedAnnotation');

Genome::Config::set_env('workflow_builder_backend', 'inline');

# create a test annotation build and a few reference sequence builds to test compatibility with
my @species_names = ('human', 'mouse');
my @versions = ('12_34', '56_78');
my $ann_pp = Genome::ProcessingProfile::ImportedAnnotation->create(name => 'test_ann_pp', annotation_source => 'test_source');
my $data_dir = File::Temp::tempdir('ImportedAnnotationTest-XXXXX', CLEANUP => 1, TMPDIR => 1);

Genome::Test::Factory::AnalysisProject->setup_system_analysis_project;
my $anp = Genome::Test::Factory::AnalysisProject->setup_object;

my %samples;
for my $sn (@species_names) {
    my $t = Genome::Taxon->__define__(name => $sn);
    my $p = Genome::Individual->create(name => "test-$sn-patient", common_name => 'testpatient', taxon => $t);
    my $s = Genome::Sample->create(name => "test-$sn-patient", common_name => 'tumor', source => $p);
    ok($s, 'created sample');
    $samples{$sn} = $s;
}
my %rbuilds = create_reference_builds(\@species_names, \@versions);

my $ann_model = Genome::Model::ImportedAnnotation->create(
    name                => "test_annotation",
    processing_profile  => $ann_pp,
    subject_class_name  => ref($samples{'human'}),
    subject_id          => $samples{'human'}->id,
    reference_sequence  => $rbuilds{'human'}->[0]->model,
);
ok($ann_model, "created annotation model");
$anp->add_model_bridge(model_id => $ann_model->id);

my $abuild = Genome::Model::Build::ImportedAnnotation->create(
    model               => $ann_model,
    data_directory      => $data_dir,
    version             => $versions[0],
);

my @tags = $abuild->validate_for_start;
ok(@tags, 'received errors when validating build, as expected');
$abuild->delete;

$abuild = Genome::Model::Build::ImportedAnnotation->create(
    model               => $ann_model,
    data_directory      => $data_dir,
    version             => $versions[0],
    reference_sequence  => $rbuilds{'human'}->[0]
);
ok($abuild, "created annotation build");
is($abuild->name, "test_annotation/$versions[0]", 'build name is correct');
$abuild = Genome::Model::Build::ImportedAnnotation->get(name => $abuild->name);
ok($abuild, 'got build by name');

$abuild->status('Succeeded');

# now set a (different) reference_sequence_build and make sure we get different answers
ok($abuild->is_compatible_with_reference_sequence_build($rbuilds{'human'}->[0]), 'reference sequence compatibility');
ok(!$abuild->is_compatible_with_reference_sequence_build($rbuilds{'human'}->[1]), 'reference sequence incompatibility');
ok(!$abuild->is_compatible_with_reference_sequence_build($rbuilds{'mouse'}->[0]), 'reference sequence incompatibility');
ok(!$abuild->is_compatible_with_reference_sequence_build($rbuilds{'mouse'}->[1]), 'reference sequence incompatibility');

my @invalid_status = ('', 'Crashed', 'Failed', 'Scheduled', 'Running', 'Abandoned');
for my $invalid (@invalid_status) {
    $abuild->status($invalid);
    ok(!$abuild->is_compatible_with_reference_sequence_build($rbuilds{'human'}->[0]), "Build status '$invalid' not allowed as annotation build");
}

ok(!$abuild->validate_for_start, "annotation build has no validate_for_start");
$abuild->reference_sequence($rbuilds{'mouse'}[0]);
my @errs = $abuild->validate_for_start;
is(scalar @errs, 1, "attempting to specify a reference build from the wrong model is an error");
like($errs[0]->desc, qr/is not a build of model/, "error string looks correct");

my $roi_data_dir = Genome::Config::get('test_inputs') . "/Genome-Model-Build-ImportedAnnotation/v3";
my $roi_expected_file = $roi_data_dir."/expected.bed";
my $roi_expected_file2 = $roi_data_dir."/expected2.bed";
my $roi_expected_file3 = $roi_data_dir."/expected3.bed";

my $sn = 'alien';
my $t = Genome::Taxon->__define__(name => $sn);
my $p = Genome::Individual->create(name => "test-$sn-patient", common_name => 'testpatient', taxon => $t);
my $s = Genome::Sample->create(name => "test-$sn-patient", common_name => 'tumor', source => $p);

my $roi_ref_build = create_roi_build($s);

my $roi_model = Genome::Model::ImportedAnnotation->create(
    name                => "test_roi",
    processing_profile  => $ann_pp,
    subject_class_name  => ref($s),
    subject_id          => $s->id,
    reference_sequence  => $roi_ref_build->model,
    );

ok ($roi_model, 'Model to test roi created');

my $roi_build = Genome::Model::Build::ImportedAnnotation->create(
    name => "test_roi_build",
    model => $roi_model,
    data_directory => $roi_data_dir,
    version             => $versions[0],
    reference_sequence  => $roi_ref_build,
    );

ok ($roi_build,'Build to test roi created');
my $roi_feature_list = $roi_build->get_or_create_roi_bed;

ok ($roi_feature_list, 'ROI feature list created');
isa_ok($roi_feature_list, 'Genome::FeatureList', 'is a FeatureList');

ok(-s $roi_feature_list->file_path, 'ROI file exists at '.$roi_feature_list->file_path);

my $file_path = $roi_feature_list->file_path;

my $roi_diff = Genome::Sys->diff_file_vs_file($roi_feature_list->file_path, $roi_expected_file);

ok(!$roi_diff, 'Content of ROI was as expected');

my $roi_feature_list2 = $roi_build->get_or_create_roi_bed(excluded_reference_sequence_patterns => ["^HS","^Un","^MT","^LRG"],
                                                          included_feature_type_patterns => ["cds_exon","rna"],
                                                          condense_feature_name => 1,
                                                          );

ok ($roi_feature_list2, 'ROI feature list created');
isa_ok($roi_feature_list2, 'Genome::FeatureList', 'is a FeatureList');
ok(-s $roi_feature_list2->file_path, 'ROI file exists at '.$roi_feature_list2->file_path);

$file_path = $roi_feature_list2->file_path;
$roi_diff = Genome::Sys->diff_file_vs_file($roi_feature_list2->file_path, $roi_expected_file2);

ok(!$roi_diff, 'Content of customized ROI was as expected');
my $roi_feature_list3 = $roi_build->get_or_create_roi_bed(excluded_reference_sequence_patterns => ["^HS","^Un","^MT","^LRG"],
                                                          included_feature_type_patterns => ["cds_exon","rna"],
                                                          condense_feature_name => 1,
                                                          flank_size => 2,
                     );
ok ($roi_feature_list3, 'ROI feature list created');
isa_ok($roi_feature_list3, 'Genome::FeatureList', 'is a FeatureList');

ok(-s $roi_feature_list3->file_path, 'ROI file exists at '.$roi_feature_list3->file_path);

$file_path = $roi_feature_list3->file_path;
$roi_diff = Genome::Sys->diff_file_vs_file($roi_feature_list3->file_path, $roi_expected_file3);

ok(!$roi_diff, 'Content of customized ROI with flanking bp was as expected');
done_testing();

sub create_reference_builds {
    my ($species_names, $versions) = @_;
    my %rbuilds;
    my $ref_pp = Genome::ProcessingProfile::ImportedReferenceSequence->create(name => 'test_ref_pp');
    for my $sn (@$species_names) {
        $rbuilds{$sn} = [];

        my $ref_model = Genome::Model::ImportedReferenceSequence->create(
            name                => "test_ref_sequence_$sn",
            processing_profile  => $ref_pp,
            subject_class_name  => ref($samples{$sn}),
            subject_id          => $samples{$sn}->id,
        );
        ok($ref_model, "created reference sequence model ($sn)");

        for my $v (@$versions) {
            $v =~ /.*_([0-9]+)/;
            my $short_version = $1;
            my $sequence_uri = "http://genome.wustl.edu/foo/bar/test.fa.gz";
            my $rs = Genome::Model::Build::ImportedReferenceSequence->create(
                name            => "ref_sequence_${sn}_$short_version",
                model           => $ref_model,
                fasta_file      => 'nofile',
                data_directory  => $data_dir,
                version         => $short_version,
                );
            ok($rs, "created ref seq build $sn $v");
            push(@{$rbuilds{$sn}}, $rs);
        }
    }
    return %rbuilds;
}

sub create_roi_build {
    my $sample = shift;
    my $pp = Genome::ProcessingProfile::ImportedReferenceSequence->create(name => 'test_ref_pp2');

    my $sequence_uri = "http://genome.wustl.edu/foo/bar/test.fa.gz";

    my $fasta_file1 = "$data_dir/data.fa";
    my $fasta_fh = new IO::File(">$fasta_file1");
    $fasta_fh->write(">HI\nNACTGACTGNNACTGN\n");
    $fasta_fh->close();


    my $command = Genome::Model::Command::Define::ImportedReferenceSequence->create(
        fasta_file => $fasta_file1,
        model_name => 'test-import-anno-1',
        processing_profile => $pp,
        species_name => $sample->taxon->name,
        subject => $s,
        version => 42,
        sequence_uri => $sequence_uri
    );

    ok($command, 'created command');

    ok($command->execute(), 'executed command');

    my $build_id = $command->result_build_id;

    my $build = Genome::Model::Build->get($build_id);

    return $build;
}
