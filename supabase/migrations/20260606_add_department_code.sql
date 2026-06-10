-- Add department_code field to departments table
ALTER TABLE public.departments ADD COLUMN IF NOT EXISTS code VARCHAR(50);

-- Add unique constraint for department code per organization
ALTER TABLE public.departments
ADD CONSTRAINT uk_departments_code_organization
UNIQUE (code, organization_id);

-- Create index on code for faster search
CREATE INDEX IF NOT EXISTS idx_departments_code
ON public.departments(code);

-- Check the column was added successfully
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'departments'
AND column_name = 'code';
