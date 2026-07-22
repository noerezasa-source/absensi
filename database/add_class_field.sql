-- Add class_name field to organization_members table
ALTER TABLE public.organization_members ADD COLUMN IF NOT EXISTS class_name VARCHAR(50);

-- Update existing members with default class (optional)
-- Uncomment the line below to set a default class for existing members
-- UPDATE public.organization_members SET class_name = 'X RPL 1' WHERE class_name IS NULL;

-- Check the column was added successfully
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'organization_members'
AND column_name = 'class_name';
