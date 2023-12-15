use fltk::{button::Button, enums::Event, frame::Frame, prelude::*, *};
// use lopdf::dictionary;

// use lopdf::content::{Content, Operation};
use lopdf::{Bookmark, Document, Object, ObjectId};
use std::collections::BTreeMap;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

fn main() {
    let app = app::App::default();
    let buf: text::TextBuffer = text::TextBuffer::default();
    let mut wind = window::Window::default().with_size(800, 600);
    let mut title: Frame = frame::Frame::default()
        .with_size(0, 40)
        .with_label("文件列表"); // 占位
    let mut output_file_path: Frame = frame::Frame::default()
        .with_size(600, 40)
        .with_label("输出文件名为第一个文件目录下: 时间_merged.pdf(如 20231215135923_merged.pdf)"); // 占位
                                                                                                    // let mut output_disp = text::TextEditor::default_fill().with_size(80, 40);
    let mut disp = text::TextDisplay::default_fill().with_size(800, 400);
    let mut btn_merge = Button::new(400, 500, 80, 40, "合并");
    let mut btn_clear = Button::new(300, 500, 80, 40, "清空列表");
    //计算上面两个按钮的宽度, 并放置到右边
    title.set_pos(380, 0);

    output_file_path.set_pos(0, 460);
    // output_disp.set_pos(100, 460);
    // output_disp.set_color(Color::White);
    // disp.set_pos(0, 40);
    disp.set_buffer(buf.clone());

    disp.handle({
        let mut dnd = false;
        let mut released = false;
        let mut buf = buf.clone();
        move |_, ev| match ev {
            Event::DndEnter => {
                dnd = true;
                true
            }
            Event::DndDrag => true,
            Event::DndRelease => {
                released = true;
                true
            }
            Event::Paste => {
                if dnd && released {
                    let path: String = app::event_text();
                    if path.to_lowercase().ends_with("pdf") {
                        buf.append(&(path + "\n"));
                    } else {
                        let choice = dialog::alert(0, 0, "包含非 PDF 文件!");
                        println!("{:?}", choice);
                    }

                    dnd = false;
                    released = false;
                    true
                } else {
                    false
                }
            }
            Event::DndLeave => {
                dnd = false;
                released = false;
                true
            }
            _ => false,
        }
    });
    btn_clear.set_callback({
        let mut buf = buf.clone();
        move |_| {
            buf.set_text("");
        }
    });

    btn_merge.set_callback({
        let buf = buf.clone();

        move |_| {
            let file_list = buf.text();
            let file_list = file_list.trim();
            let lines: Vec<&str> = file_list.split('\n').collect(); // 使用 \n 切割并收集到向量中
            if lines.len() == 0 {
                let choice = dialog::alert(0, 0, "合成失败");
                println!("{:?}", choice);
            } else {
                // output_file_path.with_label();
                let ele1 = lines.get(0).unwrap();
                let file_path = Path::new(ele1);
                let file_path = file_path.parent().unwrap();
                let fp = file_path.display().to_string();
                let now = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_secs();

                let fp = format!("{}/{}_merged.pdf", fp, now);

                merge_pdf(lines.clone(), &fp);
                let fp = format!("合成成功, 路径为:\n{}", fp);
                let choice = dialog::alert(0, 0, &fp);
                println!("{:?}", choice);
            }
        }
    });
    wind.end();
    wind.show();
    app.run().unwrap();
}
//合并 pdf 到同一个文件中
fn merge_pdf(documents: Vec<&str>, to_path: &str) {

    let mut max_id = 1;
    let mut pagenum = 1;
    // Collect all Documents Objects grouped by a map
    let mut documents_pages = BTreeMap::new();
    let mut documents_objects = BTreeMap::new();
    let mut document = Document::with_version("1.5");

    for doc_path in documents {
        let mut first = false;
        let mut doc = Document::load(doc_path).unwrap();
        doc.renumber_objects_with(max_id);

        max_id = doc.max_id + 1;

        documents_pages.extend(
            doc.get_pages()
                .into_iter()
                .map(|(_, object_id)| {
                    if !first {
                        let bookmark = Bookmark::new(
                            String::from(format!("Page_{}", pagenum)),
                            [0.0, 0.0, 1.0],
                            0,
                            object_id,
                        );
                        document.add_bookmark(bookmark, None);
                        first = true;
                        pagenum += 1;
                    }

                    (object_id, doc.get_object(object_id).unwrap().to_owned())
                })
                .collect::<BTreeMap<ObjectId, Object>>(),
        );
        documents_objects.extend(doc.objects);
    }

    // Catalog and Pages are mandatory
    let mut catalog_object: Option<(ObjectId, Object)> = None;
    let mut pages_object: Option<(ObjectId, Object)> = None;

    // Process all objects except "Page" type
    for (object_id, object) in documents_objects.iter() {
        // We have to ignore "Page" (as are processed later), "Outlines" and "Outline" objects
        // All other objects should be collected and inserted into the main Document
        match object.type_name().unwrap_or("") {
            "Catalog" => {
                // Collect a first "Catalog" object and use it for the future "Pages"
                catalog_object = Some((
                    if let Some((id, _)) = catalog_object {
                        id
                    } else {
                        *object_id
                    },
                    object.clone(),
                ));
            }
            "Pages" => {
                // Collect and update a first "Pages" object and use it for the future "Catalog"
                // We have also to merge all dictionaries of the old and the new "Pages" object
                if let Ok(dictionary) = object.as_dict() {
                    let mut dictionary = dictionary.clone();
                    if let Some((_, ref object)) = pages_object {
                        if let Ok(old_dictionary) = object.as_dict() {
                            dictionary.extend(old_dictionary);
                        }
                    }

                    pages_object = Some((
                        if let Some((id, _)) = pages_object {
                            id
                        } else {
                            *object_id
                        },
                        Object::Dictionary(dictionary),
                    ));
                }
            }
            "Page" => {}     // Ignored, processed later and separately
            "Outlines" => {} // Ignored, not supported yet
            "Outline" => {}  // Ignored, not supported yet
            _ => {
                document.objects.insert(*object_id, object.clone());
            }
        }
    }

    // If no "Pages" object found abort
    if pages_object.is_none() {
        println!("Pages root not found.");

        return;
    }

    // Iterate over all "Page" objects and collect into the parent "Pages" created before
    for (object_id, object) in documents_pages.iter() {
        if let Ok(dictionary) = object.as_dict() {
            let mut dictionary = dictionary.clone();
            dictionary.set("Parent", pages_object.as_ref().unwrap().0);

            document
                .objects
                .insert(*object_id, Object::Dictionary(dictionary));
        }
    }

    // If no "Catalog" found abort
    if catalog_object.is_none() {
        println!("Catalog root not found.");

        return;
    }

    let catalog_object = catalog_object.unwrap();
    let pages_object = pages_object.unwrap();

    // Build a new "Pages" with updated fields
    if let Ok(dictionary) = pages_object.1.as_dict() {
        let mut dictionary = dictionary.clone();

        // Set new pages count
        dictionary.set("Count", documents_pages.len() as u32);

        // Set new "Kids" list (collected from documents pages) for "Pages"
        dictionary.set(
            "Kids",
            documents_pages
                .into_iter()
                .map(|(object_id, _)| Object::Reference(object_id))
                .collect::<Vec<_>>(),
        );

        document
            .objects
            .insert(pages_object.0, Object::Dictionary(dictionary));
    }

    // Build a new "Catalog" with updated fields
    if let Ok(dictionary) = catalog_object.1.as_dict() {
        let mut dictionary = dictionary.clone();
        dictionary.set("Pages", pages_object.0);
        dictionary.remove(b"Outlines"); // Outlines not supported in merged PDFs

        document
            .objects
            .insert(catalog_object.0, Object::Dictionary(dictionary));
    }

    document.trailer.set("Root", catalog_object.0);

    // Update the max internal ID as wasn't updated before due to direct objects insertion
    document.max_id = document.objects.len() as u32;

    // Reorder all new Document objects
    document.renumber_objects();

    //Set any Bookmarks to the First child if they are not set to a page
    document.adjust_zero_pages();

    //Set all bookmarks to the PDF Object tree then set the Outlines to the Bookmark content map.
    if let Some(n) = document.build_outline() {
        if let Ok(x) = document.get_object_mut(catalog_object.0) {
            if let Object::Dictionary(ref mut dict) = x {
                dict.set("Outlines", Object::Reference(n));
            }
        }
    }

    document.compress();

    // Save the merged PDF
    // Store file in current working directory.
    // Note: Line is excluded when running tests
    if true {
        document.save(to_path).unwrap();
    }
}
