CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE roles (
    role_id SERIAL PRIMARY KEY,
    role_name VARCHAR(50) UNIQUE NOT NULL,
    description TEXT
);

INSERT INTO roles (role_name, description)
VALUES
('Admin', 'System administrator'),
('Doctor', 'Doctor account'),
('Patient', 'Patient account');
--('Receptionist', 'Receptionist account');

CREATE TABLE users (
    user_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
	phone_number VARCHAR(20) NOT NULL,
    email VARCHAR(255) NOT NULL,
    password_hash TEXT NOT NULL, -- mật khẩu được hash ở tầng back-end
    role_id INT NOT NULL REFERENCES roles(role_id),
    status VARCHAR(20) DEFAULT 'Active'
        CHECK (status IN ('Active', 'Locked', 'Inactive')),
	avatar_url TEXT, -- phần hình ảnh của bác sĩ họ có ko được cập nhật thông tin cá nhân mà tất cả đều do admin cập nhật lên
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
	
	CHECK(phone_number ~ '^[0-9]{10}$'),
	CHECK(email ~ '^[A-Za-z0-9._%+-]+@gmail\.com$')
);
CREATE UNIQUE INDEX idx_users_phone ON users(phone_number);
CREATE UNIQUE INDEX idx_users_email_lower ON users (LOWER(email));

CREATE TABLE specialties (
    specialty_id SERIAL PRIMARY KEY,
    specialty_name VARCHAR(100) UNIQUE NOT NULL,
    description TEXT,
    status BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
	-- Muốn hiển thị chuyên khoa đó có mấy bác sĩ thì cần join bảng doctors
);

CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    user_id UUID UNIQUE NOT NULL REFERENCES users(user_id) ON DELETE NO ACTION,
    full_name VARCHAR(255),
    date_of_birth DATE, 
    gender VARCHAR(20)
        CHECK (gender IN ('Male', 'Female', 'Other')),
    address TEXT,
    health_insurance_number VARCHAR(50),
	UNIQUE(health_insurance_number),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
	-- Nếu muốn khóa Patient chỉ cần khóa ở Users.status
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    user_id UUID UNIQUE NOT NULL REFERENCES users(user_id) ON DELETE NO ACTION,
    specialty_id INT REFERENCES specialties(specialty_id),
    full_name VARCHAR(255) NULL,
    degree VARCHAR(255),
    experience_years INT DEFAULT 0,
	CHECK (experience_years >= 0),
    clinic_room VARCHAR(50),
	leave_start_date DATE,
	leave_end_date DATE,
	CONSTRAINT chk_leave_dates 
		CHECK (leave_start_date IS NULL OR leave_end_date IS NULL
				OR leave_start_date <= leave_end_date),
    status VARCHAR(20) DEFAULT 'Active'
        CHECK (status IN ('Active', 'Inactive', 'OnLeave')),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Khi bác sĩ chuyển sang 'OnLeave', các ca làm việc (doctor_schedules) sắp tới của họ sẽ tự động đóng lại 
-- và cả (doctor_schedule_slots) tính từ ngày để OnLeave, 
-- không thì bệnh nhân vẫn đặt được lịch với bác sĩ đang nghỉ, trong trường hợp nếu như Booked
CREATE OR REPLACE FUNCTION close_schedules_on_leave()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status = 'OnLeave'
       AND (
            OLD.status <> 'OnLeave'
            OR NEW.leave_end_date <> OLD.leave_end_date
            OR NEW.leave_start_date <> OLD.leave_start_date
       )
    THEN
        IF NEW.leave_start_date IS NULL OR NEW.leave_end_date IS NULL THEN
            RAISE EXCEPTION 'You must enter the start and end dates of your leave.';
        END IF;

        -- 1. Đóng các ca nằm TRONG khoảng ngày nghỉ
        UPDATE doctor_schedules
        SET status = 'Unavailable'
        WHERE doctor_id = NEW.doctor_id
          AND work_date BETWEEN NEW.leave_start_date AND NEW.leave_end_date
          AND status = 'Available';

        -- 2. Đóng slot con còn trống trong các ca vừa đóng ở bước 1
        UPDATE doctor_schedule_slots
        SET status = 'Closed'
        WHERE schedule_id IN (
            SELECT schedule_id
            FROM doctor_schedules
            WHERE doctor_id = NEW.doctor_id
              AND work_date BETWEEN NEW.leave_start_date AND NEW.leave_end_date
              AND status = 'Unavailable'
        )
        AND status = 'Available';

    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_close_schedules_on_leave
AFTER UPDATE 
ON doctors
FOR EACH ROW
EXECUTE FUNCTION close_schedules_on_leave();

CREATE TABLE doctor_schedules (
    schedule_id SERIAL PRIMARY KEY,
    doctor_id INT NOT NULL REFERENCES doctors(doctor_id) ON DELETE NO ACTION,
    work_date DATE NOT NULL,
    start_time TIME NOT NULL,
    end_time TIME NOT NULL,
	UNIQUE(doctor_id, work_date, start_time),
	CHECK (start_time<end_time),
	
    status VARCHAR(20) DEFAULT 'Available'
        CHECK (status IN ('Available', 'Unavailable')),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Hệ thống back-end sẽ xử lý phần chia ca làm việc thành các lịch làm việc nhỏ (chi tiết ở docs phần database)
CREATE TABLE doctor_schedule_slots (
    slot_id SERIAL PRIMARY KEY,
    schedule_id INT NOT NULL REFERENCES doctor_schedules(schedule_id) ON DELETE CASCADE,

    slot_order INT NOT NULL,

    start_time TIME NOT NULL,
    end_time TIME NOT NULL,

    UNIQUE(schedule_id, start_time),
    UNIQUE(schedule_id, slot_order),

    status VARCHAR(20)
        DEFAULT 'Available'
        CHECK (status IN ('Available', 'Booked', 'Closed')),

    CHECK (start_time < end_time),
	CHECK (slot_order > 0),

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE appointment_statuses (
    status_id SERIAL PRIMARY KEY,
    status_name VARCHAR(50) UNIQUE NOT NULL
);

INSERT INTO appointment_statuses(status_name)
VALUES
('Scheduled'),
('Waiting'),
('InProgress'),
('Completed'),
('Cancelled'),
('NoShow');

CREATE TABLE appointments (
    appointment_id SERIAL PRIMARY KEY,
    patient_id INT NOT NULL REFERENCES patients(patient_id),
    doctor_id INT NOT NULL REFERENCES doctors(doctor_id),
    slot_id INT NOT NULL REFERENCES doctor_schedule_slots(slot_id),
    
	reason TEXT,

    status_id INT NOT NULL REFERENCES appointment_statuses(status_id),

	is_active BOOLEAN NOT NULL DEFAULT TRUE, 
	
    queue_number INT NOT NULL,
	CHECK (queue_number > 0),
    cancel_reason TEXT,
    cancelled_at TIMESTAMP,
    cancelled_by UUID REFERENCES users(user_id),
    note TEXT,

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 2. Partial unique index: chỉ chặn trùng slot_id trong số appointment đang active
CREATE UNIQUE INDEX idx_appointments_slot_active
ON appointments(slot_id)
WHERE is_active = TRUE;

-- 3. Trigger tự set is_active = FALSE khi hủy (chỉ 'Cancelled', không phải 'NoShow')
CREATE OR REPLACE FUNCTION mark_appointment_inactive_on_cancel()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status_id <> OLD.status_id THEN
        IF EXISTS (
            SELECT 1 FROM appointment_statuses
            WHERE status_id = NEW.status_id
              AND status_name = 'Cancelled'
        ) THEN
            NEW.is_active := FALSE;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_mark_appointment_inactive
BEFORE UPDATE
ON appointments
FOR EACH ROW
EXECUTE FUNCTION mark_appointment_inactive_on_cancel();

CREATE TABLE medical_records (
    medical_record_id SERIAL PRIMARY KEY,

    appointment_id INT UNIQUE NOT NULL REFERENCES appointments(appointment_id),
    patient_id INT NOT NULL REFERENCES patients(patient_id),
    doctor_id INT NOT NULL REFERENCES doctors(doctor_id),

    symptoms TEXT,
    diagnosis TEXT,
    conclusion TEXT,
    treatment_plan TEXT,
    doctor_note TEXT,

    examination_date TIMESTAMP NOT NULL,
    re_examination_date DATE,

    status VARCHAR(30) DEFAULT 'Draft' CHECK (status IN('Draft', 'Completed')),

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE medicine_categories(
	category_id SERIAL PRIMARY KEY,
	category_name VARCHAR(100) UNIQUE NOT NULL,
	description TEXT,
	
	status VARCHAR(20) 
		DEFAULT 'Active'
		CHECK (status IN ('Active', 'Inactive')),
	created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
	updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE medicines (
    medicine_id SERIAL PRIMARY KEY,
	
	category_id INT NOT NULL REFERENCES medicine_categories(category_id) ON DELETE NO ACTION,
    
	medicine_name VARCHAR(255) UNIQUE NOT NULL,
    unit VARCHAR(50) NOT NULL,
    description TEXT,
    default_usage TEXT,
	
    status VARCHAR(20) 
		DEFAULT 'Active'
        CHECK (status IN ('Active', 'Inactive')),
		
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
	
	CHECK(TRIM(unit) <> '')
);


CREATE TABLE prescriptions (
    prescription_id SERIAL PRIMARY KEY,

    medical_record_id INT UNIQUE NOT NULL REFERENCES medical_records(medical_record_id),
    doctor_id INT NOT NULL REFERENCES doctors(doctor_id),
    patient_id INT NOT NULL REFERENCES patients(patient_id),

    status VARCHAR(20) DEFAULT 'Active'
        CHECK (status IN ('Active', 'Cancelled', 'Completed')),
    note TEXT,

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE prescription_details (
    prescription_detail_id SERIAL PRIMARY KEY,

    prescription_id INT NOT NULL
        REFERENCES prescriptions(prescription_id)
        ON DELETE CASCADE,

    medicine_id INT NOT NULL
        REFERENCES medicines(medicine_id),

    -- Snapshot thông tin thuốc tại thời điểm kê đơn
    medicine_name_snapshot VARCHAR(255) NOT NULL,
    unit_snapshot VARCHAR(50) NOT NULL,

    quantity INT NOT NULL,
    CHECK (quantity > 0),

    dosage VARCHAR(100) NOT NULL,
    frequency VARCHAR(100) NOT NULL,
    duration VARCHAR(100) NOT NULL,
    usage_instruction TEXT,
    note TEXT,

    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE notifications (
    notification_id SERIAL PRIMARY KEY,

    user_id UUID NOT NULL REFERENCES users(user_id) ON DELETE NO ACTION,

    title VARCHAR(255) NOT NULL,
    content TEXT NOT NULL,
    type VARCHAR(50) NOT NULL,
    related_id INT,
    related_type VARCHAR(50),

    is_read BOOLEAN DEFAULT FALSE,
    read_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
	-- để nhận được thông báo, bộ phận back-end sẽ làm điều này 
);

---------------------------------------------------------------------
CREATE INDEX idx_doctors_specialty ON doctors(specialty_id);
CREATE INDEX idx_appointments_patient ON appointments(patient_id);
CREATE INDEX idx_appointments_doctor ON appointments(doctor_id);
-- Tìm slot còn trống
CREATE INDEX idx_slots_status ON doctor_schedule_slots(status);
-- Tìm lịch của bác sĩ
CREATE INDEX idx_schedules_date ON doctor_schedules(work_date);
CREATE INDEX idx_notifications_user ON notifications(user_id);
CREATE INDEX idx_schedules_doctor_date ON doctor_schedules(doctor_id, work_date);

CREATE INDEX idx_patients_user ON patients(user_id);

CREATE INDEX idx_doctors_user ON doctors(user_id);

CREATE INDEX idx_prescriptions_patient ON prescriptions(patient_id);

CREATE INDEX idx_prescriptions_doctor ON prescriptions(doctor_id);

CREATE INDEX idx_prescription_details_prescription ON prescription_details(prescription_id);

CREATE INDEX idx_slots_schedule ON doctor_schedule_slots(schedule_id);

CREATE INDEX idx_appointments_status ON appointments(status_id);

---------------------------------------------------------------------
--TRIGGER
CREATE OR REPLACE FUNCTION check_schedule_overlap()
RETURNS TRIGGER AS $$
DECLARE
    doc_status VARCHAR(20);
    leave_start DATE;
    leave_end DATE;
BEGIN
    -- kiểm tra trùng giờ 
    IF EXISTS (
        SELECT 1 FROM doctor_schedules
        WHERE doctor_id = NEW.doctor_id
          AND work_date = NEW.work_date
          AND schedule_id <> NEW.schedule_id
          AND NEW.start_time < end_time
          AND NEW.end_time > start_time
    ) THEN
        RAISE EXCEPTION 'Doctor already has another schedule during this time.';
    END IF;

    -- kiểm tra bác sĩ có đang nghỉ phép đúng ngày này không
    SELECT status, leave_start_date, leave_end_date
    INTO doc_status, leave_start, leave_end
    FROM doctors WHERE doctor_id = NEW.doctor_id;

    IF doc_status = 'OnLeave'
		AND leave_start IS NOT NULL
		AND leave_end IS NOT NULL
		AND NEW.work_date BETWEEN leave_start AND leave_end THEN
        RAISE EXCEPTION 'Doctor is on leave on this date.';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_schedule_overlap
BEFORE INSERT OR UPDATE
ON doctor_schedules
FOR EACH ROW
EXECUTE FUNCTION check_schedule_overlap();
---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS
$$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_users_updated_at
BEFORE UPDATE
ON users
FOR EACH ROW
EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_doctors_updated_at
BEFORE UPDATE
ON doctors
FOR EACH ROW
EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_patients_updated_at
BEFORE UPDATE
ON patients
FOR EACH ROW
EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_specialties_updated_at
BEFORE UPDATE
ON specialties
FOR EACH ROW
EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_schedules_updated_at
BEFORE UPDATE
ON doctor_schedules
FOR EACH ROW
EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_slots_updated_at
BEFORE UPDATE
ON doctor_schedule_slots
FOR EACH ROW
EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_appointments_updated_at
BEFORE UPDATE
ON appointments
FOR EACH ROW
EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_medical_records_updated_at
BEFORE UPDATE
ON medical_records
FOR EACH ROW
EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_medicines_updated_at
BEFORE UPDATE
ON medicines
FOR EACH ROW
EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_prescriptions_updated_at
BEFORE UPDATE
ON prescriptions
FOR EACH ROW
EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_prescription_details_updated_at
BEFORE UPDATE
ON prescription_details
FOR EACH ROW
EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_medicine_categories_updated_at
BEFORE UPDATE
ON medicine_categories
FOR EACH ROW
EXECUTE FUNCTION update_updated_at();
---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_queue_number()
RETURNS TRIGGER AS $$
BEGIN
    SELECT slot_order
    INTO NEW.queue_number
    FROM doctor_schedule_slots
    WHERE slot_id = NEW.slot_id;

	IF NEW.queue_number IS NULL THEN
        RAISE EXCEPTION 'Invalid slot.';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_set_queue_number
BEFORE INSERT
ON appointments
FOR EACH ROW
EXECUTE FUNCTION set_queue_number();

---------------------------------------------------------------------
-- Trigger cập nhật Slot thành Booked
CREATE OR REPLACE FUNCTION update_slot_status_booked()
RETURNS TRIGGER AS $$
BEGIN

    UPDATE doctor_schedule_slots
    SET status = 'Booked'
    WHERE slot_id = NEW.slot_id;

    RETURN NEW;

END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_slot_booked
AFTER INSERT
ON appointments
FOR EACH ROW
EXECUTE FUNCTION update_slot_status_booked();

---------------------------------------------------------------------
-- Trigger khi hủy Appointment
CREATE OR REPLACE FUNCTION update_slot_status_available()
RETURNS TRIGGER AS $$
BEGIN

    IF NEW.status_id <>
       OLD.status_id THEN

        IF EXISTS (
            SELECT 1
            FROM appointment_statuses
            WHERE status_id = NEW.status_id
              AND status_name = 'Cancelled'
        )
        THEN

            UPDATE doctor_schedule_slots
            SET status = 'Available'
            WHERE slot_id = NEW.slot_id;

        END IF;

    END IF;

    RETURN NEW;

END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_slot_available
AFTER UPDATE
ON appointments
FOR EACH ROW
EXECUTE FUNCTION update_slot_status_available();
---------------------------------------------------------------------
-- Trigger kiểm tra doctor_id của Appointment
CREATE OR REPLACE FUNCTION check_appointment_doctor()
RETURNS TRIGGER AS
$$
DECLARE
    slot_doctor_id INT;
BEGIN

    SELECT ds.doctor_id
    INTO slot_doctor_id
    FROM doctor_schedule_slots s
    JOIN doctor_schedules ds
        ON ds.schedule_id = s.schedule_id
    WHERE s.slot_id = NEW.slot_id;

    IF slot_doctor_id IS NULL THEN
        RAISE EXCEPTION 'Invalid slot.';
    END IF;

    IF slot_doctor_id <> NEW.doctor_id THEN
        RAISE EXCEPTION
        'Doctor does not match selected schedule slot.';
    END IF;

    RETURN NEW;

END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_appointment_doctor
BEFORE INSERT OR UPDATE
ON appointments
FOR EACH ROW
EXECUTE FUNCTION check_appointment_doctor();

---------------------------------------------------------------------
-- Trigger snapshot thuốc
CREATE OR REPLACE FUNCTION set_medicine_snapshot()
RETURNS TRIGGER AS
$$
BEGIN

    SELECT
        medicine_name,
        unit
    INTO
        NEW.medicine_name_snapshot,
        NEW.unit_snapshot
    FROM medicines
    WHERE medicine_id = NEW.medicine_id;

    IF NEW.medicine_name_snapshot IS NULL THEN
        RAISE EXCEPTION 'Medicine not found.';
    END IF;

    RETURN NEW;

END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_set_medicine_snapshot
BEFORE INSERT
ON prescription_details
FOR EACH ROW
EXECUTE FUNCTION set_medicine_snapshot();
---------------------------------------------------------------------
-- Trigger khi tạo users với role Patient và Doctor sẽ tự
-- động insert vào bảng Patients và Doctors
CREATE OR REPLACE FUNCTION create_profile_on_user_insert()
RETURNS TRIGGER AS $$
DECLARE
	v_role_name VARCHAR(50);
BEGIN
	-- Lấy tên role tương ứng với role_id vừa insert
	SELECT role_name INTO v_role_name
	FROM roles
	WHERE role_id = NEW.role_id;
	
	IF v_role_name = 'Patient' THEN
		INSERT INTO patients (user_id)
		VALUES (NEW.user_id);
		
	ELSIF v_role_name = 'Doctor' THEN
		INSERT INTO doctors (user_id)
		VALUES (NEW.user_id);
	END IF;
	
	RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_create_profile_on_user_insert
AFTER INSERT ON users
FOR EACH ROW
EXECUTE FUNCTION create_profile_on_user_insert();

-- một điều cần bạn lưu ý khi code phần backend/ui
-- vì giờ full_name có thể null, ở màn hình danh sách bệnh nhân/bác sĩ 
-- (như bảng #000001 - nguyen van an bạn gửi lúc trước), 
-- cần xử lý hiển thị khi full_name is null — ví dụ hiện tạm "(chưa cập nhật tên)" ở tầng hiển thị (c#/react), 
-- không lưu chuỗi đó vào db, chỉ hiện khi render:
-- csharp:
-- string displayname = string.isnullorempty(patient.fullname)
    -- ? "(chưa cập nhật tên)"
    -- : patient.fullname;
-- CẦN PHẢI HIỆN THÔNG BÁO CHO NGƯỜI DÙNG NGƯỜI TA CẬP NHẬT THÔNG TIN CÁ NHÂN (ĐỀ ĐẦY ĐỦ THÔNG TIN)

------------------------------------------------------------------------------------------------------------------------------------------
-- Tạo tài khoản PostgreSQL 
-- Tạo user
CREATE USER tan WITH PASSWORD 'Tan@122';
CREATE USER dang WITH PASSWORD 'Dang@245';
CREATE USER thientan WITH PASSWORD 'ThienTan@579';
-- Cấp quyền 
GRANT CONNECT ON DATABASE dtt_healthcare TO tan;
GRANT CONNECT ON DATABASE dtt_healthcare TO dang;
GRANT CONNECT ON DATABASE dtt_healthcare TO thientan;
-- Cho phép dùng schema
GRANT USAGE ON SCHEMA public TO tan;
GRANT USAGE ON SCHEMA public TO dang;
GRANT USAGE ON SCHEMA public TO thientan;
-- Cho phép thao tác trên tất cả bảng hiện có
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO tan;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO dang;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO thientan;
-- Cho phép dùng tất cả sequence (SERIAL, IDENTITY...)
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO tan;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO dang;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO thientan;
-- Để các bảng và sequence tạo trong tương lai cũng tự động cấp quyền
ALTER DEFAULT PRIVILEGES IN SCHEMA public 
GRANT ALL PRIVILEGES ON TABLES TO tan, dang, thientan;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
GRANT ALL PRIVILEGES ON SEQUENCES TO tan, dang, thientan;

---------------------------------------------------------------------------
-- Chỉnh sửa bảng patients và thêm các bảng mới (Đăng)
-- 1. Thêm verification_status cho patients
ALTER TABLE patients
  ADD COLUMN verification_status VARCHAR(20) NOT NULL DEFAULT 'Pending',
  ADD COLUMN verified_at         TIMESTAMP WITHOUT TIME ZONE,
  ADD COLUMN verified_by         UUID REFERENCES users(user_id),
  ADD COLUMN verification_note   TEXT;
ALTER TABLE patients
  ADD CONSTRAINT chk_verification_status
  CHECK (verification_status IN ('Pending', 'Verified', 'Rejected'));

-- 2. Tạo bảng kết quả xét nghiệm
CREATE TABLE medical_tests (
  test_id           SERIAL PRIMARY KEY,
  medical_record_id INTEGER NOT NULL REFERENCES medical_records(medical_record_id),
  test_name         VARCHAR(255) NOT NULL,
  test_type         VARCHAR(50),
  result_value      TEXT,
  result_status     VARCHAR(20) DEFAULT 'Pending',
  unit              VARCHAR(50),
  reference_range   VARCHAR(100),
  performed_at      TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  result_file_url   TEXT,
  created_at        TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at 		TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT chk_test_result_status CHECK (result_status IN ('Pending', 'Normal', 'Abnormal'))
);

-- 3. Tạo bảng siêu âm
CREATE TABLE ultrasound_results (
  ultrasound_id     SERIAL PRIMARY KEY,
  medical_record_id INTEGER NOT NULL REFERENCES medical_records(medical_record_id),
  ultrasound_type   VARCHAR(100),
  description       TEXT,
  conclusion        TEXT,
  image_urls        TEXT[],
  performed_at      TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_at        TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at 		TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 4. Tạo bảng hóa đơn
CREATE TABLE invoices (
  invoice_id        SERIAL PRIMARY KEY,
  appointment_id    INTEGER UNIQUE NOT NULL REFERENCES appointments(appointment_id),
  patient_id        INTEGER NOT NULL REFERENCES patients(patient_id),
  total_amount      DECIMAL(12, 2) NOT NULL DEFAULT 0, -- tự động tính bởi trigger trg_recalc_invoice_total ko insert/update cột này 
  paid_amount       DECIMAL(12, 2) NOT NULL DEFAULT 0,
  payment_status    VARCHAR(20) DEFAULT 'Unpaid',
  payment_method    VARCHAR(50),
  invoice_date      TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  created_at        TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at 		TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT chk_payment_status CHECK (payment_status IN ('Unpaid', 'Partial', 'Paid')),
  CONSTRAINT chk_paid_le_total CHECK (paid_amount <= total_amount)
);

CREATE TABLE invoice_items (
  item_id           SERIAL PRIMARY KEY,
  invoice_id        INTEGER NOT NULL REFERENCES invoices(invoice_id),
  item_name         VARCHAR(255) NOT NULL,
  item_type         VARCHAR(50),
  quantity          INTEGER NOT NULL DEFAULT 1,
  unit_price        DECIMAL(10, 2) NOT NULL,
  amount            DECIMAL(12, 2) NOT NULL,
  created_at 		TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at 		TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT chk_invoice_items_quantity CHECK (quantity > 0)
);

CREATE TRIGGER trg_medical_tests_updated_at
BEFORE UPDATE ON medical_tests
FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_ultrasound_results_updated_at
BEFORE UPDATE ON ultrasound_results
FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_invoices_updated_at
BEFORE UPDATE ON invoices
FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_invoice_items_updated_at
BEFORE UPDATE ON invoice_items
FOR EACH ROW EXECUTE FUNCTION update_updated_at();

------------------------------------------------------------
-- Trigger tự tính lại total_amount của invoices mỗi khi invoice_items thay đổi
CREATE OR REPLACE FUNCTION recalc_invoice_total()
RETURNS TRIGGER AS $$
DECLARE
    v_invoice_id INT;
BEGIN
    -- Xác định invoice_id bị ảnh hưởng
    -- (DELETE dùng OLD vì dòng đã bị xóa, không còn NEW)
    IF TG_OP = 'DELETE' THEN
        v_invoice_id := OLD.invoice_id;
    ELSE
        v_invoice_id := NEW.invoice_id;
    END IF;

    UPDATE invoices
    SET total_amount = (
        SELECT COALESCE(SUM(amount), 0)
        FROM invoice_items
        WHERE invoice_id = v_invoice_id
    )
    WHERE invoice_id = v_invoice_id;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_recalc_invoice_total
AFTER INSERT OR UPDATE OR DELETE
ON invoice_items
FOR EACH ROW
EXECUTE FUNCTION recalc_invoice_total();

---------------------------------------------------------------------------
-- Bổ sung thêm (Đăng)
-- 1. Thêm CCCD và phone vào patients
ALTER TABLE patients
  ADD COLUMN IF NOT EXISTS cccd_number  VARCHAR(12),
  ADD COLUMN IF NOT EXISTS phone_number VARCHAR(20);
-- 2. Đồng bộ verification_status về chữ thường
ALTER TABLE patients
  ALTER COLUMN verification_status SET DEFAULT 'pending';
UPDATE patients SET verification_status = LOWER(verification_status);
ALTER TABLE patients DROP CONSTRAINT IF EXISTS chk_verification_status;
ALTER TABLE patients ADD CONSTRAINT chk_verification_status
  CHECK (verification_status IN ('pending', 'verified', 'rejected'));
-- 3. Bảng hồ sơ người thân
CREATE TABLE IF NOT EXISTS family_members (
  member_id               SERIAL PRIMARY KEY,
  owner_patient_id        INTEGER NOT NULL REFERENCES patients(patient_id),
  full_name               VARCHAR(255) NOT NULL,
  date_of_birth           DATE,
  gender                  VARCHAR(20),
  relationship            VARCHAR(50) NOT NULL,
  phone_number            VARCHAR(20),
  cccd_number             VARCHAR(12),
  health_insurance_number VARCHAR(50),
  address                 TEXT,
  verification_status     VARCHAR(20) NOT NULL DEFAULT 'pending',
  verified_at             TIMESTAMP WITHOUT TIME ZONE,
  verified_by             UUID REFERENCES users(user_id),
  verification_note       TEXT,
  created_at              TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at              TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT chk_member_status
    CHECK (verification_status IN ('pending', 'verified', 'rejected'))
);
-- 4. Thêm avatar và rating cho bác sĩ
ALTER TABLE doctors
  ADD COLUMN IF NOT EXISTS avatar_url   TEXT,
  ADD COLUMN IF NOT EXISTS rating       DECIMAL(3,2) DEFAULT 5.0,
  ADD COLUMN IF NOT EXISTS review_count INTEGER DEFAULT 0;

---------------------------------------------------------------------------
-- Bổ sung thêm (Đăng 25/7/2026)
-- 1. Sửa payment_status về chữ thường
ALTER TABLE invoices
  ALTER COLUMN payment_status SET DEFAULT 'unpaid';

UPDATE invoices 
SET payment_status = LOWER(payment_status);

ALTER TABLE invoices DROP CONSTRAINT IF EXISTS chk_payment_status;
ALTER TABLE invoices ADD CONSTRAINT chk_payment_status
  CHECK (payment_status IN ('unpaid', 'partial', 'paid'));

-- 2. Tạo bảng gói khám sức khỏe
CREATE TABLE IF NOT EXISTS health_packages (
  package_id    SERIAL PRIMARY KEY,
  title         VARCHAR(255) NOT NULL,
  description   TEXT,
  price         DECIMAL(12, 2) NOT NULL,
  gender_target VARCHAR(10) DEFAULT 'all',  -- 'male' | 'female' | 'all'
  image_url     TEXT,
  booked_count  INTEGER DEFAULT 0,
  is_active     BOOLEAN DEFAULT TRUE,
  created_at    TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at    TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT chk_gender_target CHECK (gender_target IN ('male', 'female', 'all'))
);

-- Bảng chi tiết dịch vụ trong gói
CREATE TABLE IF NOT EXISTS health_package_details (
  detail_id   SERIAL PRIMARY KEY,
  package_id  INTEGER NOT NULL REFERENCES health_packages(package_id) ON DELETE CASCADE,
  service_name VARCHAR(255) NOT NULL,
  sort_order  INTEGER DEFAULT 0
);

-- Thêm dữ liệu mẫu từ MOCK của app
INSERT INTO health_packages (title, description, price, gender_target, booked_count) VALUES
  ('Khám Tổng Quát Cơ Bản - Nam', 
   'Gói khám được thiết kế chuyên biệt cho nam giới, giúp tầm soát và phát hiện sớm các bệnh lý phổ biến.',
   1200000, 'male', 1200),
  ('Khám Tổng Quát Cơ Bản - Nữ', 
   'Gói khám toàn diện dành cho nữ giới, bao gồm các chỉ số sức khỏe tổng quát và siêu âm tuyến vú/phụ khoa cơ bản.',
   1450000, 'female', 2000),
  ('Tầm soát Ung thư Vú & Cổ tử cung', 
   'Tầm soát chuyên sâu giúp phát hiện sớm các dấu hiệu của ung thư vú và ung thư cổ tử cung ở phụ nữ.',
   2500000, 'female', 500),
  ('Tầm soát Bệnh lý Tim mạch', 
   'Gói tầm soát dành cho người có nguy cơ cao về tim mạch, huyết áp.',
   1800000, 'all', 800);
---------------------------------------------------------------------------
-- Bổ sung thêm (Đăng 27/7/2026)
-- ==============================================================================
-- 1. THÊM CHỈ SỐ SINH TỒN & LÝ DO NHẬP VIỆN VÀO HỒ SƠ BỆNH ÁN (medical_records)
-- ==============================================================================
ALTER TABLE medical_records
  ADD COLUMN IF NOT EXISTS admission_reason TEXT,              -- Lý do vào viện / Triệu chứng sơ bộ
  ADD COLUMN IF NOT EXISTS blood_pressure VARCHAR(20),        -- Huyết áp (Vd: '120/80')
  ADD COLUMN IF NOT EXISTS heart_rate INTEGER,                -- Nhịp tim (bpm)
  ADD COLUMN IF NOT EXISTS temperature DECIMAL(4, 2),         -- Nhiệt độ cơ thể (°C)
  ADD COLUMN IF NOT EXISTS height DECIMAL(5, 2),              -- Chiều cao (cm)
  ADD COLUMN IF NOT EXISTS weight DECIMAL(5, 2),              -- Cân nặng (kg)
  ADD COLUMN IF NOT EXISTS bmi DECIMAL(4, 2),                 -- Chỉ số khối cơ thể (BMI)
  ADD COLUMN IF NOT EXISTS icd_code VARCHAR(20),             -- Mã ICD-10 (Vd: 'J06.9')
  ADD COLUMN IF NOT EXISTS icd_description VARCHAR(255);     -- Tên chẩn đoán chuẩn theo ICD-10

-- ==============================================================================
-- 2. TẠO TỪ ĐIỂN DỊCH VỤ CẬN LÂM SÀNG (CLS) & LIÊN CHUYỂN BỆNH ÁN
-- ==============================================================================
CREATE TABLE IF NOT EXISTS clinical_services (
  service_id      SERIAL PRIMARY KEY,
  service_code    VARCHAR(50) UNIQUE NOT NULL,      -- Vd: 'LAB01', 'IMG01'
  service_name    VARCHAR(255) NOT NULL,            -- Vd: 'Xét nghiệm máu tổng quát'
  service_type    VARCHAR(50) NOT NULL,             -- 'Laboratory' (Xét nghiệm) hoặc 'Imaging' (Chẩn đoán ảnh)
  department      VARCHAR(100),                     -- Phòng ban thụ lý
  unit_price      NUMERIC NOT NULL DEFAULT 0,       -- Đơn giá dịch vụ (VNĐ)
  description     TEXT,
  is_active       BOOLEAN DEFAULT true,
  created_at      TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at      TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

ALTER TABLE ultrasound_results
  ADD COLUMN IF NOT EXISTS result_status VARCHAR(20) DEFAULT 'Pending',
  ADD COLUMN IF NOT EXISTS service_id INTEGER REFERENCES clinical_services(service_id);
  
ALTER TABLE medical_tests
  ADD COLUMN IF NOT EXISTS service_id INTEGER REFERENCES clinical_services(service_id);

-- ==============================================================================
-- 3. BỘ TIÊU CHÍ KHO THUỐC, HOẠT CHẤT & ĐƠN GIÁ CHO BẢNG MEDICINES
-- ==============================================================================
ALTER TABLE medicines
  ADD COLUMN IF NOT EXISTS unit_price NUMERIC NOT NULL DEFAULT 0,      -- Giá mỗi đơn vị (Hộp/Viên)
  ADD COLUMN IF NOT EXISTS stock_quantity INTEGER NOT NULL DEFAULT 0,  -- Tồn kho phòng khám
  ADD COLUMN IF NOT EXISTS expiry_date DATE;                           -- Hạn sử dụng của thuốc

-- ==============================================================================
-- 4. ĐỒNG BỘ KHÁM CHỮA BỆNH CHO NGƯỜI THÂN (FAMILY MEMBERS BINDING)
-- ==============================================================================
ALTER TABLE appointments
  ADD COLUMN IF NOT EXISTS member_id INTEGER REFERENCES family_members(member_id) ON DELETE SET NULL;
ALTER TABLE medical_records
  ADD COLUMN IF NOT EXISTS member_id INTEGER REFERENCES family_members(member_id) ON DELETE SET NULL;
ALTER TABLE invoices
  ADD COLUMN IF NOT EXISTS member_id INTEGER REFERENCES family_members(member_id) ON DELETE SET NULL;

-- ==============================================================================
-- 5. TẠO TỪ ĐIỂN MÃ BỆNH QUỐC TẾ ICD-10 (CHO WINFORMS AUTOCOMPLETE)
-- ==============================================================================
CREATE TABLE IF NOT EXISTS icd10_catalog (
  icd_code        VARCHAR(20) PRIMARY KEY,
  disease_name    VARCHAR(255) NOT NULL,
  chapter_name    VARCHAR(255),
  is_common       BOOLEAN DEFAULT false
);

-- ==============================================================================
-- 6. TẠO NHẬT KÝ BẢO MẬT & KIỂM THỬ LÂM SÀNG (MEDICAL AUDIT LOGS)
-- ==============================================================================
CREATE TABLE IF NOT EXISTS user_activity_logs (
  log_id          SERIAL PRIMARY KEY,
  user_id         UUID REFERENCES users(user_id),
  action_type     VARCHAR(100) NOT NULL,        -- 'START_EXAM', 'ISSUE_PRESCRIPTION', 'ORDER_LAB'
  entity_name     VARCHAR(100),                 -- 'medical_records', 'prescriptions'
  entity_id       INTEGER,
  ip_address      VARCHAR(50),
  created_at      TIMESTAMP WITHOUT TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- ==============================================================================
-- 7. NẠP DỮ LIỆU MẪU CHUNG (SEED DATA) CHO WINFORMS & APP MOBILE
-- ==============================================================================
-- Nạp Dịch vụ CLS tương thích tuyệt đối với 7 Checkbox trên ảnh KhamBenh.png:
INSERT INTO clinical_services (service_code, service_name, service_type, department, unit_price)
VALUES 
  ('LAB_BLOOD', 'Xét nghiệm máu tổng quát', 'Laboratory', 'Phòng Xét nghiệm Tầng 2', 150000),
  ('LAB_URINE', 'Xét nghiệm nước tiểu', 'Laboratory', 'Phòng Xét nghiệm Tầng 2', 100000),
  ('IMG_XRAY',  'X-Quang ngực thẳng/nghiêng', 'Imaging',    'Phòng Chẩn đoán hình ảnh Tầng 3', 250000),
  ('IMG_ULTRA', 'Siêu âm bụng tổng quát',     'Imaging',    'Phòng Siêu âm Tầng 3', 200000),
  ('IMG_CT',    'CT Scanner Sọ não / Ngực',   'Imaging',    'Phòng CT/MRI Tầng 3', 1500000),
  ('LAB_ECG',   'Điện tâm đồ (ECG)',          'Functional', 'Phòng Thăm dò chức năng', 180000),
  ('LAB_GLU',   'Xét nghiệm đường huyết',     'Laboratory', 'Phòng Xét nghiệm Tầng 2', 80000)
ON CONFLICT (service_code) DO UPDATE SET unit_price = EXCLUDED.unit_price;

-- Nạp 10 mã Bệnh lý ICD-10 phổ biến nhất cho Từ điển Bác sĩ:
INSERT INTO icd10_catalog (icd_code, disease_name, chapter_name, is_common)
VALUES
  ('J06.9', 'Viêm đường hô hấp trên cấp tính, không xác định', 'Bệnh hệ hô hấp', true),
  ('I10',   'Tăng huyết áp vô căn (nguyên phát)', 'Bệnh hệ tuần hoàn', true),
  ('E11',   'Bệnh đái tháo đường tuýp 2', 'Bệnh nội tiết và chuyển hóa', true),
  ('K21.9', 'Bệnh trào ngược dạ dày - thực quản không kèm viêm', 'Bệnh hệ tiêu hóa', true),
  ('J20.9', 'Viêm phế quản cấp, không xác định', 'Bệnh hệ hô hấp', true),
  ('R51',   'Đau đầu / Nhức đầu không xác định', 'Triệu chứng lâm sàng chung', true),
  ('J02.9', 'Viêm họng cấp tính, không xác định', 'Bệnh hệ hô hấp', true),
  ('A09',   'Tiêu chảy và viêm dạ dày ruột do nhiễm trùng', 'Bệnh nhiễm trùng', true),
  ('M54.5', 'Đau thắt lưng (Đau lưng dưới)', 'Bệnh hệ cơ xương khớp', true),
  ('J03.9', 'Viêm amidan cấp, không xác định', 'Bệnh hệ hô hấp', true)
ON CONFLICT (icd_code) DO NOTHING;
