-- Merges the Pegasus schema @source_schema (pegasus, from the prod space) into @target_schema (pegasus_stage, which is
-- kept as it is). Run MergeSchemasCheck.sql first, and try this on a copy of the target before running it for real:
-- it is not transactional here, so a failure part way leaves a partly merged schema.
--
-- Both schemas have to be on the data model of CreateDataModel.sql. Rows of the source that do not collide keep their
-- ids. A source row whose id is already used in the target gets a new id above every id in either schema, and every
-- row that points at it follows (phenotype, concept set, cohort definition and evaluation request ids). The final
-- query lists the phenotypes that were renumbered, so people can be told their new ids.
--
-- Not merged: database_meta_data rows that already exist in the target (databases are shared, same ids), atlas_instance
-- (the target has it), and the run progress and run request tables (pegasus_run*), which belong to the backend's runs
-- of one environment.

-- ---------------------------------------------------------------------------------------------------------------
-- Part 1: the new id of every source row (the same id when it does not collide)
-- ---------------------------------------------------------------------------------------------------------------

CREATE TABLE #phenotype_map (old_id INT NOT NULL, new_id INT NOT NULL);

INSERT INTO #phenotype_map (old_id, new_id)
SELECT s.phenotype_id,
  CASE
    WHEN t.phenotype_id IS NULL THEN s.phenotype_id
    ELSE b.base_id + ROW_NUMBER() OVER (PARTITION BY CASE WHEN t.phenotype_id IS NULL THEN 0 ELSE 1 END ORDER BY s.phenotype_id)
  END
FROM @source_schema.phenotype s
LEFT JOIN @target_schema.phenotype t ON t.phenotype_id = s.phenotype_id
CROSS JOIN (
  SELECT MAX(id) AS base_id FROM (
    SELECT COALESCE(MAX(phenotype_id), 0) AS id FROM @source_schema.phenotype
    UNION ALL
    SELECT COALESCE(MAX(phenotype_id), 0) FROM @target_schema.phenotype
  ) m
) b;

CREATE TABLE #concept_set_map (old_id INT NOT NULL, new_id INT NOT NULL);

INSERT INTO #concept_set_map (old_id, new_id)
SELECT s.concept_set_id,
  CASE
    WHEN t.concept_set_id IS NULL THEN s.concept_set_id
    ELSE b.base_id + ROW_NUMBER() OVER (PARTITION BY CASE WHEN t.concept_set_id IS NULL THEN 0 ELSE 1 END ORDER BY s.concept_set_id)
  END
FROM @source_schema.concept_set s
LEFT JOIN @target_schema.concept_set t ON t.concept_set_id = s.concept_set_id
CROSS JOIN (
  SELECT MAX(id) AS base_id FROM (
    SELECT COALESCE(MAX(concept_set_id), 0) AS id FROM @source_schema.concept_set
    UNION ALL
    SELECT COALESCE(MAX(concept_set_id), 0) FROM @target_schema.concept_set
  ) m
) b;

CREATE TABLE #cohort_definition_map (old_id INT NOT NULL, new_id INT NOT NULL);

INSERT INTO #cohort_definition_map (old_id, new_id)
SELECT s.cohort_definition_id,
  CASE
    WHEN t.cohort_definition_id IS NULL THEN s.cohort_definition_id
    ELSE b.base_id + ROW_NUMBER() OVER (PARTITION BY CASE WHEN t.cohort_definition_id IS NULL THEN 0 ELSE 1 END ORDER BY s.cohort_definition_id)
  END
FROM @source_schema.cohort_definition s
LEFT JOIN @target_schema.cohort_definition t ON t.cohort_definition_id = s.cohort_definition_id
CROSS JOIN (
  SELECT MAX(id) AS base_id FROM (
    SELECT COALESCE(MAX(cohort_definition_id), 0) AS id FROM @source_schema.cohort_definition
    UNION ALL
    SELECT COALESCE(MAX(cohort_definition_id), 0) FROM @target_schema.cohort_definition
  ) m
) b;

CREATE TABLE #evaluation_request_map (old_id INT NOT NULL, new_id INT NOT NULL);

INSERT INTO #evaluation_request_map (old_id, new_id)
SELECT s.evaluation_request_id,
  CASE
    WHEN t.evaluation_request_id IS NULL THEN s.evaluation_request_id
    ELSE b.base_id + ROW_NUMBER() OVER (PARTITION BY CASE WHEN t.evaluation_request_id IS NULL THEN 0 ELSE 1 END ORDER BY s.evaluation_request_id)
  END
FROM @source_schema.evaluation_request s
LEFT JOIN @target_schema.evaluation_request t ON t.evaluation_request_id = s.evaluation_request_id
CROSS JOIN (
  SELECT MAX(id) AS base_id FROM (
    SELECT COALESCE(MAX(evaluation_request_id), 0) AS id FROM @source_schema.evaluation_request
    UNION ALL
    SELECT COALESCE(MAX(evaluation_request_id), 0) FROM @target_schema.evaluation_request
  ) m
) b;

-- ---------------------------------------------------------------------------------------------------------------
-- Part 2: copy the source rows with the new ids
-- ---------------------------------------------------------------------------------------------------------------

INSERT INTO @target_schema.phenotype
SELECT m.new_id, s.phenotype_name, s.clinical_definition, s.creator, s.time_created, s.draft, s.valid
FROM @source_schema.phenotype s
INNER JOIN #phenotype_map m ON m.old_id = s.phenotype_id;

INSERT INTO @target_schema.phenotype_ancestor
SELECT pm.new_id, parent.new_id
FROM @source_schema.phenotype_ancestor s
INNER JOIN #phenotype_map pm ON pm.old_id = s.phenotype_id
INNER JOIN #phenotype_map parent ON parent.old_id = s.parent_phenotype_id;

INSERT INTO @target_schema.phenotype_meta_data
SELECT m.new_id, s.is_pharmacovigilance_outcome, s.clinical_course, s.expected_care_setting, s.sex_constraint,
  s.min_age_years, s.max_age_years, s.minimum_interepisode_gap_days, s.recommended_cohort_exit, s.recommended_exit_days,
  s.has_discrete_recorded_symptoms, s.requires_diagnostic_test_or_procedure, s.requires_active_treatment_within_30d,
  s.expects_condition_specific_followup_or_sequelae_1yr
FROM @source_schema.phenotype_meta_data s
INNER JOIN #phenotype_map m ON m.old_id = s.phenotype_id;

INSERT INTO @target_schema.draft_concept_set_target
SELECT m.new_id, s.pertains, s.category, s.term, s.concept_id, s.concept_name, s.domain_id, s.concept_class_id,
  s.vocabulary_id, s.match_type
FROM @source_schema.draft_concept_set_target s
INNER JOIN #phenotype_map m ON m.old_id = s.phenotype_id;

INSERT INTO @target_schema.draft_target_to_concept_set
SELECT pm.new_id, s.pertains, s.category, s.concept_id, cm.new_id
FROM @source_schema.draft_target_to_concept_set s
INNER JOIN #phenotype_map pm ON pm.old_id = s.phenotype_id
INNER JOIN #concept_set_map cm ON cm.old_id = s.concept_set_id;

INSERT INTO @target_schema.concept_set
SELECT m.new_id, s.concept_set_name, s.circe_concept_set_expression, s.capr_concept_set_expression, s.has_descendants,
  s.clinical_definition, s.concept_id, s.valid, s.atlas_concept_set_id, s.cs_source_type
FROM @source_schema.concept_set s
INNER JOIN #concept_set_map m ON m.old_id = s.concept_set_id;

INSERT INTO @target_schema.concept_set_item
SELECT m.new_id, s.concept_id, s.is_excluded, s.include_descendants, s.include_mapped
FROM @source_schema.concept_set_item s
INNER JOIN #concept_set_map m ON m.old_id = s.concept_set_id;

INSERT INTO @target_schema.phenotype_to_concept_set
SELECT pm.new_id, s.pertains, s.category, cm.new_id
FROM @source_schema.phenotype_to_concept_set s
INNER JOIN #phenotype_map pm ON pm.old_id = s.phenotype_id
INNER JOIN #concept_set_map cm ON cm.old_id = s.concept_set_id;

-- Databases are shared: only the ones the target does not have yet are added, with their ids
INSERT INTO @target_schema.database_meta_data
SELECT s.database_id, s.cdm_source_name, s.cdm_source_abbreviation, s.cdm_release_date, s.cdm_release_identifier,
  s.vocabulary_version, s.cdm_database_schema, s.result_database_schema
FROM @source_schema.database_meta_data s
LEFT JOIN @target_schema.database_meta_data t ON t.database_id = s.database_id
WHERE t.database_id IS NULL;

INSERT INTO @target_schema.concept_set_person_count
SELECT m.new_id, s.database_id, s.condition_persons, s.procedure_persons, s.drug_persons, s.device_persons,
  s.measurement_persons, s.observation_persons, s.visit_persons, s.overall_persons
FROM @source_schema.concept_set_person_count s
INNER JOIN #concept_set_map m ON m.old_id = s.concept_set_id;

INSERT INTO @target_schema.cohort_definition
SELECT cm.new_id, s.cohort_definition_name, pm.new_id, s.circe_cohort_expression, s.capr_cohort_expression,
  s.cd_source_type, s.valid, s.atlas_cohort_definition_id
FROM @source_schema.cohort_definition s
INNER JOIN #cohort_definition_map cm ON cm.old_id = s.cohort_definition_id
INNER JOIN #phenotype_map pm ON pm.old_id = s.phenotype_id;

INSERT INTO @target_schema.cohort_definition_to_concept_set
SELECT cdm.new_id, csm.new_id
FROM @source_schema.cohort_definition_to_concept_set s
INNER JOIN #cohort_definition_map cdm ON cdm.old_id = s.cohort_definition_id
INNER JOIN #concept_set_map csm ON csm.old_id = s.concept_set_id;

INSERT INTO @target_schema.cohort_definition_evaluation
SELECT m.new_id, s.database_id, s.cohort_entries, s.cohort_subjects, s.generation_seconds, s.true_positives,
  s.false_positives, s.true_negatives, s.false_negatives, s.ppv, s.ppv_lb, s.ppv_ub, s.sensitivity, s.sensitivity_lb,
  s.sensitivity_ub, s.specificity, s.specificity_lb, s.specificity_ub, s.npv, s.npv_lb, s.npv_ub, s.evaluation_type
FROM @source_schema.cohort_definition_evaluation s
INNER JOIN #cohort_definition_map m ON m.old_id = s.cohort_definition_id;

INSERT INTO @target_schema.evaluation_request
SELECT em.new_id, cdm.new_id, s.database_id, s.evaluation_type, s.requested_by, s.time_requested, s.notes
FROM @source_schema.evaluation_request s
INNER JOIN #evaluation_request_map em ON em.old_id = s.evaluation_request_id
INNER JOIN #cohort_definition_map cdm ON cdm.old_id = s.cohort_definition_id;

-- ---------------------------------------------------------------------------------------------------------------
-- Part 3: what was done
-- ---------------------------------------------------------------------------------------------------------------

-- The phenotypes that got a new id
SELECT m.old_id AS old_phenotype_id, m.new_id AS new_phenotype_id, p.phenotype_name
FROM #phenotype_map m
INNER JOIN @target_schema.phenotype p ON p.phenotype_id = m.new_id
WHERE m.old_id <> m.new_id
ORDER BY m.old_id;

-- Rows copied per table (rows of the source, and what the target now has)
SELECT 'phenotype' AS table_name, (SELECT COUNT(*) FROM @source_schema.phenotype) AS source_rows, (SELECT COUNT(*) FROM @target_schema.phenotype) AS target_rows
UNION ALL SELECT 'phenotype_ancestor', (SELECT COUNT(*) FROM @source_schema.phenotype_ancestor), (SELECT COUNT(*) FROM @target_schema.phenotype_ancestor)
UNION ALL SELECT 'phenotype_meta_data', (SELECT COUNT(*) FROM @source_schema.phenotype_meta_data), (SELECT COUNT(*) FROM @target_schema.phenotype_meta_data)
UNION ALL SELECT 'draft_concept_set_target', (SELECT COUNT(*) FROM @source_schema.draft_concept_set_target), (SELECT COUNT(*) FROM @target_schema.draft_concept_set_target)
UNION ALL SELECT 'draft_target_to_concept_set', (SELECT COUNT(*) FROM @source_schema.draft_target_to_concept_set), (SELECT COUNT(*) FROM @target_schema.draft_target_to_concept_set)
UNION ALL SELECT 'concept_set', (SELECT COUNT(*) FROM @source_schema.concept_set), (SELECT COUNT(*) FROM @target_schema.concept_set)
UNION ALL SELECT 'concept_set_item', (SELECT COUNT(*) FROM @source_schema.concept_set_item), (SELECT COUNT(*) FROM @target_schema.concept_set_item)
UNION ALL SELECT 'phenotype_to_concept_set', (SELECT COUNT(*) FROM @source_schema.phenotype_to_concept_set), (SELECT COUNT(*) FROM @target_schema.phenotype_to_concept_set)
UNION ALL SELECT 'concept_set_person_count', (SELECT COUNT(*) FROM @source_schema.concept_set_person_count), (SELECT COUNT(*) FROM @target_schema.concept_set_person_count)
UNION ALL SELECT 'cohort_definition', (SELECT COUNT(*) FROM @source_schema.cohort_definition), (SELECT COUNT(*) FROM @target_schema.cohort_definition)
UNION ALL SELECT 'cohort_definition_to_concept_set', (SELECT COUNT(*) FROM @source_schema.cohort_definition_to_concept_set), (SELECT COUNT(*) FROM @target_schema.cohort_definition_to_concept_set)
UNION ALL SELECT 'cohort_definition_evaluation', (SELECT COUNT(*) FROM @source_schema.cohort_definition_evaluation), (SELECT COUNT(*) FROM @target_schema.cohort_definition_evaluation)
UNION ALL SELECT 'evaluation_request', (SELECT COUNT(*) FROM @source_schema.evaluation_request), (SELECT COUNT(*) FROM @target_schema.evaluation_request)
UNION ALL SELECT 'database_meta_data', (SELECT COUNT(*) FROM @source_schema.database_meta_data), (SELECT COUNT(*) FROM @target_schema.database_meta_data);

DROP TABLE #evaluation_request_map;
DROP TABLE #cohort_definition_map;
DROP TABLE #concept_set_map;
DROP TABLE #phenotype_map;
