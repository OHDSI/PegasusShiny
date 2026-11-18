-- Read-only check to run before MergeSchemas.sql. Set @target_schema (pegasus_stage, the schema that is kept) and
-- @source_schema (pegasus, the schema that is merged into it). Nothing is written.
--
-- 1. Ids that exist in both schemas. These get new ids in the merge (see MergeSchemas.sql), which is fine.
-- 2. Names that exist in both schemas. phenotype_name and cohort_definition_name are unique, so these stop the merge:
--    resolve them (rename one or delete the duplicate) before merging.
-- 3. Databases whose id exists in both schemas but that are not the same database. Databases are shared, so their ids
--    are kept as they are; any row listed here has to be sorted out by hand.

SELECT 'phenotype' AS entity, COUNT(*) AS ids_in_both
FROM @source_schema.phenotype s INNER JOIN @target_schema.phenotype t ON t.phenotype_id = s.phenotype_id
UNION ALL
SELECT 'concept_set', COUNT(*)
FROM @source_schema.concept_set s INNER JOIN @target_schema.concept_set t ON t.concept_set_id = s.concept_set_id
UNION ALL
SELECT 'cohort_definition', COUNT(*)
FROM @source_schema.cohort_definition s INNER JOIN @target_schema.cohort_definition t ON t.cohort_definition_id = s.cohort_definition_id
UNION ALL
SELECT 'evaluation_request', COUNT(*)
FROM @source_schema.evaluation_request s INNER JOIN @target_schema.evaluation_request t ON t.evaluation_request_id = s.evaluation_request_id;

-- The colliding phenotypes, side by side
SELECT s.phenotype_id, s.phenotype_name AS source_name, t.phenotype_name AS target_name
FROM @source_schema.phenotype s
INNER JOIN @target_schema.phenotype t ON t.phenotype_id = s.phenotype_id
ORDER BY s.phenotype_id;

-- Names in both schemas (any row here stops the merge)
SELECT 'phenotype' AS entity, s.phenotype_name AS name, s.phenotype_id AS source_id, t.phenotype_id AS target_id
FROM @source_schema.phenotype s
INNER JOIN @target_schema.phenotype t ON t.phenotype_name = s.phenotype_name
UNION ALL
SELECT 'cohort_definition', s.cohort_definition_name, s.cohort_definition_id, t.cohort_definition_id
FROM @source_schema.cohort_definition s
INNER JOIN @target_schema.cohort_definition t ON t.cohort_definition_name = s.cohort_definition_name;

-- Database ids that mean different databases in the two schemas (any row here has to be sorted out by hand)
SELECT s.database_id,
  s.cdm_source_abbreviation AS source_abbreviation, t.cdm_source_abbreviation AS target_abbreviation,
  s.cdm_release_identifier AS source_release, t.cdm_release_identifier AS target_release
FROM @source_schema.database_meta_data s
INNER JOIN @target_schema.database_meta_data t ON t.database_id = s.database_id
WHERE s.cdm_source_abbreviation <> t.cdm_source_abbreviation
  OR COALESCE(s.cdm_release_identifier, '') <> COALESCE(t.cdm_release_identifier, '');
